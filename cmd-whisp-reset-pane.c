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
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
 * IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include <sys/types.h>

#include "tmux.h"

/* Reset a pane's server-side terminal state without touching its process. */

static enum cmd_retval	cmd_whisp_reset_pane_exec(struct cmd *,
			    struct cmdq_item *);

const struct cmd_entry cmd_whisp_reset_pane_entry = {
	.name = "whisp-reset-pane",
	.alias = NULL,

	.args = { "Ht:", 0, 0, NULL },
	.usage = "[-H] " CMD_TARGET_PANE_USAGE,

	.target = { 't', CMD_FIND_PANE, 0 },

	.flags = 0,
	.exec = cmd_whisp_reset_pane_exec
};

static enum cmd_retval
cmd_whisp_reset_pane_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args			*args = cmd_get_args(self);
	struct window_pane		*wp = cmdq_get_target(item)->wp;
	struct screen_write_ctx	 ctx;

	/* Reset window modes before touching the pane's base screen. */
	window_pane_reset_mode_all(wp);

	/* Drop any stuck alternate screen before resetting the base screen. */
	if (SCREEN_IS_ALTERNATE(&wp->base))
		screen_alternate_off(&wp->base, NULL, 0);

	/* Stop synchronized output and reset the parser's pending input state. */
	screen_write_stop_sync(wp);
	colour_palette_clear(&wp->palette);
	if (wp->ictx != NULL)
		input_reset(wp->ictx, 0);

	/*
	 * Do not give the writer a pane: screen_write_clearscreen() otherwise
	 * honors scroll-on-clear and moves the visible rows into history.
	 */
	screen_write_start(&ctx, &wp->base);
	screen_write_reset(&ctx);
	screen_write_stop(&ctx);

	if (args_has(args, 'H'))
		grid_clear_history(wp->base.grid);

	/* Do not let a later mismatched alternate-screen cycle restore old state. */
	wp->base.saved_cx = wp->base.saved_cy = UINT_MAX;

	wp->flags |= (PANE_STYLECHANGED|PANE_THEMECHANGED|PANE_REDRAW);
	return (CMD_RETURN_NORMAL);
}
