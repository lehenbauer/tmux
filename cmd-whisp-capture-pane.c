/* $OpenBSD$ */

/*
 * Copyright (c) 2026 Karl Lehenbauer <karl@flightaware.com>
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

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "tmux.h"

/*
 * Capture pane lines using immutable Whisp line numbers.
 */

static enum cmd_retval	cmd_whisp_capture_pane_exec(struct cmd *,
			    struct cmdq_item *);

static int	cmd_whisp_capture_pane_parse_line(struct args *, u_char,
		    uint64_t *, struct cmdq_item *);
static int	cmd_whisp_capture_pane_find_line(struct grid *, uint64_t,
		    u_int *);
static int	cmd_whisp_capture_pane_range(struct grid *, u_int, u_int, int,
		    u_int *, u_int *, uint64_t *, u_int *);
static char	*cmd_whisp_capture_pane_append(char *, size_t *, const char *,
		    size_t);
static char	*cmd_whisp_capture_pane_lines(struct args *, struct window_pane *,
		    u_int, u_int, uint64_t, u_int, size_t *);
static void	cmd_whisp_capture_pane_position(struct args *, u_char,
		    struct cmdq_item *, struct grid *, u_int, u_int *);
static void	cmd_whisp_capture_pane_grid_range(struct args *,
		    struct cmdq_item *, struct grid *, u_int *, u_int *);
static char	*cmd_whisp_capture_pane_line_range(struct args *,
		    struct cmdq_item *, struct window_pane *, size_t *);
static enum cmd_retval cmd_whisp_capture_pane_print(struct cmdq_item *, char *,
		    size_t);

const struct cmd_entry cmd_whisp_capture_pane_entry = {
	.name = "whisp-capture-pane",
	.alias = NULL,

	.args = { "A:B:CeE:JLNn:qS:Tt:", 0, 0, NULL },
	.usage = "[-CeJNqT] [-A after-line | -B before-line] -n lines "
		 "[-L [-CeNqT] [-E end-line] [-S start-line]] "
		 CMD_TARGET_PANE_USAGE,

	.target = { 't', CMD_FIND_PANE, 0 },

	.flags = CMD_AFTERHOOK,
	.exec = cmd_whisp_capture_pane_exec
};

static int
cmd_whisp_capture_pane_parse_line(struct args *args, u_char flag,
    uint64_t *line_number, struct cmdq_item *item)
{
	const char		*value = args_get(args, flag);
	char			*endptr;
	unsigned long long	 n;

	if (value == NULL) {
		cmdq_error(item, "missing -%c", flag);
		return (-1);
	}
	if (*value == '\0' || *value == '-' || *value == '+') {
		cmdq_error(item, "invalid line number: %s", value);
		return (-1);
	}

	errno = 0;
	n = strtoull(value, &endptr, 10);
	if (errno == ERANGE || *endptr != '\0' || n == 0 || n > UINT64_MAX) {
		cmdq_error(item, "invalid line number: %s", value);
		return (-1);
	}
	*line_number = n;
	return (0);
}

static int
cmd_whisp_capture_pane_find_line(struct grid *gd, uint64_t line_number,
    u_int *py)
{
	const struct grid_line	*gl;
	u_int			 yy, total = gd->hsize + gd->sy;

	for (yy = 0; yy < total; yy++) {
		gl = grid_peek_line(gd, yy);
		if (gl->line_number == line_number) {
			*py = yy;
			return (0);
		}
	}
	return (-1);
}

static int
cmd_whisp_capture_pane_range(struct grid *gd, u_int found, u_int count,
    int after, u_int *top, u_int *bottom, uint64_t *cursor, u_int *actual)
{
	const struct grid_line	*gl;
	u_int			 yy, total = gd->hsize + gd->sy;

	*actual = 0;
	if (after) {
		for (yy = found + 1; yy < total && *actual < count; yy++) {
			gl = grid_peek_line(gd, yy);
			if (gl->line_number == 0)
				continue;
			if (*actual == 0)
				*top = yy;
			*bottom = yy;
			*cursor = gl->line_number;
			(*actual)++;
		}
	} else {
		yy = found;
		while (yy > 0 && *actual < count) {
			yy--;
			gl = grid_peek_line(gd, yy);
			if (gl->line_number == 0)
				continue;
			*top = yy;
			if (*actual == 0)
				*bottom = yy;
			*cursor = gl->line_number;
			(*actual)++;
		}
	}
	return (*actual == 0 ? -1 : 0);
}

static char *
cmd_whisp_capture_pane_append(char *buf, size_t *len, const char *line,
    size_t linelen)
{
	buf = xrealloc(buf, *len + linelen + 1);
	memcpy(buf + *len, line, linelen);
	*len += linelen;
	return (buf);
}

static char *
cmd_whisp_capture_pane_lines(struct args *args, struct window_pane *wp,
    u_int top, u_int bottom, uint64_t cursor, u_int count, size_t *len)
{
	struct screen		*s = &wp->base;
	struct grid		*gd = s->grid;
	const struct grid_line	*gl;
	struct grid_cell	*gc = NULL;
	char			*buf = NULL, *line, header[64];
	size_t			 linelen;
	u_int			 i, sx = screen_size_x(s);
	int			 flags = 0, join_lines;

	join_lines = args_has(args, 'J');
	if (args_has(args, 'e'))
		flags |= GRID_STRING_WITH_SEQUENCES;
	if (args_has(args, 'C'))
		flags |= GRID_STRING_ESCAPE_SEQUENCES;
	if (!join_lines && !args_has(args, 'T'))
		flags |= GRID_STRING_EMPTY_CELLS;
	if (!join_lines && !args_has(args, 'N'))
		flags |= GRID_STRING_TRIM_SPACES;

	xsnprintf(header, sizeof header, "cursor=%llu\tcount=%u\n",
	    (unsigned long long)cursor, count);
	buf = cmd_whisp_capture_pane_append(buf, len, header, strlen(header));

	for (i = top; i <= bottom; i++) {
		gl = grid_peek_line(gd, i);
		if (gl->line_number == 0)
			continue;

		line = grid_string_cells(gd, 0, i, sx, &gc, flags, s);
		linelen = strlen(line);
		buf = cmd_whisp_capture_pane_append(buf, len, line, linelen);
		if (!join_lines || !(gl->flags & GRID_LINE_WRAPPED))
			buf[(*len)++] = '\n';

		free(line);
	}
	return (buf);
}

static void
cmd_whisp_capture_pane_position(struct args *args, u_char flag,
    struct cmdq_item *item, struct grid *gd, u_int default_py, u_int *py)
{
	const char	*value = args_get(args, flag);
	char		*cause;
	int		 n;

	if (value == NULL) {
		*py = default_py;
		return;
	}
	if (strcmp(value, "-") == 0) {
		if (flag == 'S')
			*py = 0;
		else
			*py = gd->hsize + gd->sy - 1;
		return;
	}

	n = args_strtonum_and_expand(args, flag, INT_MIN, SHRT_MAX, item,
	    &cause);
	if (cause != NULL) {
		*py = default_py;
		free(cause);
	} else if (n < 0 && (u_int)-n > gd->hsize)
		*py = 0;
	else
		*py = gd->hsize + n;
	if (*py > gd->hsize + gd->sy - 1)
		*py = gd->hsize + gd->sy - 1;
}

static void
cmd_whisp_capture_pane_grid_range(struct args *args, struct cmdq_item *item,
    struct grid *gd, u_int *top, u_int *bottom)
{
	u_int	tmp;

	cmd_whisp_capture_pane_position(args, 'S', item, gd, gd->hsize, top);
	cmd_whisp_capture_pane_position(args, 'E', item, gd,
	    gd->hsize + gd->sy - 1, bottom);
	if (*bottom < *top) {
		tmp = *bottom;
		*bottom = *top;
		*top = tmp;
	}
}

static char *
cmd_whisp_capture_pane_line_range(struct args *args, struct cmdq_item *item,
    struct window_pane *wp, size_t *len)
{
	struct screen		*s = &wp->base;
	struct grid		*gd = s->grid;
	const struct grid_line	*gl;
	struct grid_cell	*gc = NULL;
	char			*buf = NULL, *line, prefix[64];
	size_t			 linelen;
	u_int			 i, sx = screen_size_x(s), top, bottom;
	int			 flags = 0;

	if (args_has(args, 'e'))
		flags |= GRID_STRING_WITH_SEQUENCES;
	if (args_has(args, 'C'))
		flags |= GRID_STRING_ESCAPE_SEQUENCES;
	if (!args_has(args, 'T'))
		flags |= GRID_STRING_EMPTY_CELLS;
	if (!args_has(args, 'N'))
		flags |= GRID_STRING_TRIM_SPACES;

	cmd_whisp_capture_pane_grid_range(args, item, gd, &top, &bottom);
	for (i = top; i <= bottom; i++) {
		gl = grid_peek_line(gd, i);
		if (gl == NULL || gl->line_number == 0)
			continue;

		xsnprintf(prefix, sizeof prefix, "%llu\t",
		    (unsigned long long)gl->line_number);
		buf = cmd_whisp_capture_pane_append(buf, len, prefix,
		    strlen(prefix));

		line = grid_string_cells(gd, 0, i, sx, &gc, flags, s);
		linelen = strlen(line);
		buf = cmd_whisp_capture_pane_append(buf, len, line, linelen);
		buf[(*len)++] = '\n';

		free(line);
	}
	if (buf == NULL)
		buf = xstrdup("");
	return (buf);
}

static enum cmd_retval
cmd_whisp_capture_pane_print(struct cmdq_item *item, char *buf, size_t len)
{
	struct client	*c = cmdq_get_client(item);

	if (len == 0) {
		free(buf);
		return (CMD_RETURN_NORMAL);
	}
	if (buf[len - 1] == '\n')
		len--;

	if (c->flags & CLIENT_CONTROL)
		control_write(c, "%.*s", (int)len, buf);
	else {
		if (!file_can_print(c)) {
			cmdq_error(item, "can't write to client");
			free(buf);
			return (CMD_RETURN_ERROR);
		}
		file_print_buffer(c, buf, len);
		file_print(c, "\n");
	}

	free(buf);
	return (CMD_RETURN_NORMAL);
}

static enum cmd_retval
cmd_whisp_capture_pane_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args		*args = cmd_get_args(self);
	struct window_pane	*wp = cmdq_get_target(item)->wp;
	struct grid		*gd = wp->base.grid;
	uint64_t		 line_number, cursor;
	u_int			 found, top, bottom, count, actual;
	long long		 n;
	char			*cause, *buf;
	size_t			 len = 0;
	int			 anchor_mode, line_mode;

	anchor_mode = args_has(args, 'A') || args_has(args, 'B');
	line_mode = args_has(args, 'L') || args_has(args, 'S') ||
	    args_has(args, 'E');

	if (!anchor_mode) {
		if (!args_has(args, 'L')) {
			cmdq_error(item, "missing -L");
			return (CMD_RETURN_ERROR);
		}
		if (args_has(args, 'J')) {
			cmdq_error(item, "-L and -J are incompatible");
			return (CMD_RETURN_ERROR);
		}
		buf = cmd_whisp_capture_pane_line_range(args, item, wp, &len);
		return (cmd_whisp_capture_pane_print(item, buf, len));
	}
	if (line_mode) {
		cmdq_error(item, "-L, -S and -E are incompatible with -A or -B");
		return (CMD_RETURN_ERROR);
	}
	if (args_has(args, 'A') == args_has(args, 'B')) {
		cmdq_error(item, "exactly one of -A or -B must be specified");
		return (CMD_RETURN_ERROR);
	}
	if (!args_has(args, 'n')) {
		cmdq_error(item, "missing -n");
		return (CMD_RETURN_ERROR);
	}

	n = args_strtonum(args, 'n', 1, UINT_MAX, &cause);
	if (cause != NULL) {
		cmdq_error(item, "lines %s", cause);
		free(cause);
		return (CMD_RETURN_ERROR);
	}
	count = n;

	if (cmd_whisp_capture_pane_parse_line(args,
	    args_has(args, 'A') ? 'A' : 'B', &line_number, item) != 0)
		return (CMD_RETURN_ERROR);
	if (cmd_whisp_capture_pane_find_line(gd, line_number, &found) != 0) {
		if (args_has(args, 'q'))
			return (CMD_RETURN_NORMAL);
		cmdq_error(item, "line number %llu not available",
		    (unsigned long long)line_number);
		return (CMD_RETURN_ERROR);
	}

	if (cmd_whisp_capture_pane_range(gd, found, count, args_has(args, 'A'),
	    &top, &bottom, &cursor, &actual) != 0)
		return (CMD_RETURN_NORMAL);

	buf = cmd_whisp_capture_pane_lines(args, wp, top, bottom, cursor, actual,
	    &len);
	return (cmd_whisp_capture_pane_print(item, buf, len));
}
