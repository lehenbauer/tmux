/* $OpenBSD$ */

/*
 * Copyright (c) 2026 Karl Lehenbauer
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
 * IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
 * OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include <sys/types.h>

#include <stdlib.h>
#include <string.h>

#include "tmux.h"

/*
 * Remove one pane and install its window's final layout without exposing
 * tmux's ordinary close-and-redistribute intermediate geometry to survivors.
 */

static enum cmd_retval	cmd_whisp_kill_pane_exec(struct cmd *,
			    struct cmdq_item *);

const struct cmd_entry cmd_whisp_kill_pane_entry = {
	.name = "whisp-kill-pane",

	.args = { "t:", 1, 1, NULL },
	.usage = CMD_TARGET_PANE_USAGE " layout",

	.target = { 't', CMD_FIND_PANE, 0 },

	.flags = 0,
	.exec = cmd_whisp_kill_pane_exec
};

static enum cmd_retval
cmd_whisp_kill_pane_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args			 *args = cmd_get_args(self);
	struct cmd_find_state		 *target = cmdq_get_target(item);
	struct session			 *s = target->s;
	struct winlink			 *wl = target->wl;
	struct window			 *w = wl->window;
	struct window_pane		 *wp = target->wp, *loopwp;
	struct window_pane		**survivors = NULL;
	struct layout_cell		 *lc, *lcparent;
	struct whisp_layout_parse_result parsed;
	struct cmd_find_state		  fs;
	const char			 *layout = args_string(args, 0);
	char				 *cause = NULL;
	u_int				  i, j, npanes;

	memset(&parsed, 0, sizeof parsed);

	if (wp == NULL) {
		cmdq_error(item, "no active pane to kill");
		return (CMD_RETURN_ERROR);
	}
	if (w->flags & WINDOW_ZOOMED) {
		cmdq_error(item, "can't atomically close a zoomed window");
		return (CMD_RETURN_ERROR);
	}
	if (window_has_floating_panes(w) || window_pane_is_floating(wp)) {
		cmdq_error(item, "can't atomically close a window with floating panes");
		return (CMD_RETURN_ERROR);
	}

	npanes = window_count_panes(w, 1);
	if (npanes == 1) {
		cmdq_error(item, "can't atomically close the last pane");
		return (CMD_RETURN_ERROR);
	}
	if (wp->layout_cell == NULL || wp->layout_cell->parent == NULL) {
		cmdq_error(item, "target pane has no removable layout cell");
		return (CMD_RETURN_ERROR);
	}

	if (whisp_layout_parse(layout, &parsed, &cause) != 0) {
		cmdq_error(item, "%s: %s", cause, layout);
		free(cause);
		return (CMD_RETURN_ERROR);
	}
	if (parsed.nleaves != npanes - 1) {
		cmdq_error(item, "layout has %u panes but need %u", parsed.nleaves,
		    npanes - 1);
		goto fail;
	}

	survivors = xreallocarray(NULL, parsed.nleaves, sizeof *survivors);
	for (i = 0; i < parsed.nleaves; i++) {
		if (parsed.pane_ids[i] == wp->id) {
			cmdq_error(item, "layout contains target pane %%%u", wp->id);
			goto fail;
		}
		for (j = 0; j < i; j++) {
			if (parsed.pane_ids[j] == parsed.pane_ids[i]) {
				cmdq_error(item, "layout contains duplicate pane %%%u",
				    parsed.pane_ids[i]);
				goto fail;
			}
		}
		loopwp = window_pane_find_by_id(parsed.pane_ids[i]);
		if (loopwp == NULL || loopwp->window != w) {
			cmdq_error(item, "layout pane %%%u is not a survivor",
			    parsed.pane_ids[i]);
			goto fail;
		}
		survivors[i] = loopwp;
	}

	/*
	 * All parsing, allocation, and validation is complete. Detach the target
	 * leaf without redistributing its space, then destroy the target pane.
	 */
	server_client_remove_pane(wp);
	lc = wp->layout_cell;
	lcparent = lc->parent;
	TAILQ_REMOVE(&lcparent->cells, lc, entry);
	lc->wp = NULL;
	wp->layout_cell = NULL;
	layout_free_cell(lc);
	window_remove_pane(w, wp);

	/* Replace and bind the layout in serialized leaf order. */
	layout_free_cell(w->layout_root);
	w->layout_root = parsed.root;
	parsed.root = NULL;

	while (!TAILQ_EMPTY(&w->panes)) {
		loopwp = TAILQ_FIRST(&w->panes);
		TAILQ_REMOVE(&w->panes, loopwp, entry);
	}
	for (i = 0; i < parsed.nleaves; i++) {
		TAILQ_INSERT_TAIL(&w->panes, survivors[i], entry);
		layout_make_leaf(parsed.leaves[i], survivors[i]);
	}

	/* Rebuild z-indexes only after draining survivors' existing links. */
	while (!TAILQ_EMPTY(&w->z_index)) {
		loopwp = TAILQ_FIRST(&w->z_index);
		TAILQ_REMOVE(&w->z_index, loopwp, zentry);
	}
	layout_fix_zindexes(w, w->layout_root);

	options_set_number(w->options, "window-size", WINDOW_SIZE_MANUAL);
	w->manual_sx = w->layout_root->sx;
	w->manual_sy = w->layout_root->sy;
	window_resize(w, w->manual_sx, w->manual_sy, -1, -1);
	w->flags &= ~WINDOW_RESIZE;

	layout_fix_offsets(w);
	layout_fix_panes(w, NULL);
	recalculate_sizes();
	server_redraw_window(w);
	tty_update_window_offset(w);
	notify_window("window-layout-changed", w);
	notify_window("window-resized", w);

	/*
	 * Match kill-pane's public hook contract. Do not use CMD_AFTERHOOK, which
	 * would derive after-whisp-kill-pane from this command's entry name.
	 */
	cmd_find_from_winlink_pane(&fs, wl, w->active, 0);
	cmdq_insert_hook(s, item, &fs, "after-kill-pane");

	free(survivors);
	whisp_layout_parse_free(&parsed);
	return (CMD_RETURN_NORMAL);

fail:
	free(survivors);
	whisp_layout_parse_free(&parsed);
	return (CMD_RETURN_ERROR);
}
