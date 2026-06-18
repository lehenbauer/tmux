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
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE
 * FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
 * IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
 * OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include <sys/types.h>

#include <regex.h>
#include <stdlib.h>
#include <string.h>

#include "tmux.h"

/*
 * Search retained pane history and report one row per matching pane.
 */

#define SEARCH_HISTORY_TEMPLATE					\
	"#{session_id}\t#{session_name}\t#{window_id}\t"	\
	"#{window_index}\t#{window_name}\t#{pane_id}\t"		\
	"#{pane_index}\t#{pane_title}\t#{match_count}\t"	\
	"#{matching_line_count}\t#{first_match_line}\t"		\
	"#{last_match_line}\t#{retained_first_line}\t"		\
	"#{retained_last_line}"

struct cmd_search_history_state {
	const char	*pattern;
	int		 ignore;
	int		 regex;
	int		 join;
	regex_t		 reg;
};

struct cmd_search_history_result {
	uint64_t	 match_count;
	uint64_t	 matching_line_count;
	uint64_t	 first_match_line;
	uint64_t	 last_match_line;
	uint64_t	 retained_first_line;
	uint64_t	 retained_last_line;
};

static enum cmd_retval	cmd_search_history_exec(struct cmd *,
			    struct cmdq_item *);

static int	cmd_search_history_compile(struct cmd_search_history_state *,
		    struct cmdq_item *);
static void	cmd_search_history_bounds(struct grid *,
		    struct cmd_search_history_result *);
static u_int	cmd_search_history_count_literal(const char *, const char *,
		    int);
static u_int	cmd_search_history_count_regex(regex_t *, const char *);
static u_int	cmd_search_history_count_matches(
		    struct cmd_search_history_state *, const char *);
static char	*cmd_search_history_append(char *, size_t *, const char *,
		    size_t);
static int	cmd_search_history_pane(struct window_pane *,
		    struct cmd_search_history_state *,
		    struct cmd_search_history_result *);
static void	cmd_search_history_print(struct cmd *, struct cmdq_item *,
		    struct session *, struct winlink *, struct window_pane *,
		    struct cmd_search_history_result *);

const struct cmd_entry cmd_search_history_entry = {
	.name = "whisp-search-history",
	.alias = NULL,

	.args = { "F:iJrn:", 1, 1, NULL },
	.usage = "[-iJr] [-F format] [-n max-results] pattern",

	.flags = CMD_AFTERHOOK|CMD_READONLY,
	.exec = cmd_search_history_exec
};

static int
cmd_search_history_compile(struct cmd_search_history_state *cs,
    struct cmdq_item *item)
{
	size_t	error_size;
	char	*error;
	int	error_code, flags = REG_EXTENDED;

	if (*cs->pattern == '\0') {
		cmdq_error(item, "empty search pattern");
		return (-1);
	}
	if (!cs->regex)
		return (0);

	if (cs->ignore)
		flags |= REG_ICASE;
	error_code = regcomp(&cs->reg, cs->pattern, flags);
	if (error_code == 0)
		return (0);

	error_size = regerror(error_code, &cs->reg, NULL, 0);
	error = xmalloc(error_size);
	regerror(error_code, &cs->reg, error, error_size);
	cmdq_error(item, "invalid regular expression: %s", error);
	free(error);
	return (-1);
}

static void
cmd_search_history_bounds(struct grid *gd, struct cmd_search_history_result *sr)
{
	const struct grid_line	*gl;
	u_int			 yy, total = gd->hsize + gd->sy;

	for (yy = 0; yy < total; yy++) {
		gl = grid_peek_line(gd, yy);
		if (gl == NULL || gl->line_number == 0)
			continue;
		if (sr->retained_first_line == 0)
			sr->retained_first_line = gl->line_number;
		sr->retained_last_line = gl->line_number;
	}
}

static u_int
cmd_search_history_count_literal(const char *line, const char *pattern,
    int ignore)
{
	const char	*found, *cp = line;
	size_t		 size = strlen(pattern);
	u_int		 count = 0;

	for (;;) {
		if (ignore)
			found = strcasestr(cp, pattern);
		else
			found = strstr(cp, pattern);
		if (found == NULL)
			break;
		count++;
		cp = found + size;
	}
	return (count);
}

static u_int
cmd_search_history_count_regex(regex_t *reg, const char *line)
{
	regmatch_t	 m;
	const char	*cp = line;
	u_int		 count = 0;

	while (regexec(reg, cp, 1, &m, 0) == 0) {
		if (m.rm_so == -1)
			break;
		count++;
		if (m.rm_so == m.rm_eo)
			break;
		cp += m.rm_eo;
	}
	return (count);
}

static u_int
cmd_search_history_count_matches(struct cmd_search_history_state *cs,
    const char *line)
{
	if (cs->regex)
		return (cmd_search_history_count_regex(&cs->reg, line));
	return (cmd_search_history_count_literal(line, cs->pattern, cs->ignore));
}

static char *
cmd_search_history_append(char *buf, size_t *len, const char *line,
    size_t linelen)
{
	buf = xrealloc(buf, *len + linelen + 1);
	memcpy(buf + *len, line, linelen);
	*len += linelen;
	buf[*len] = '\0';
	return (buf);
}

static int
cmd_search_history_pane(struct window_pane *wp,
    struct cmd_search_history_state *cs, struct cmd_search_history_result *sr)
{
	struct screen		*s = &wp->base;
	struct grid		*gd = s->grid;
	const struct grid_line	*gl;
	char			*line, *next;
	size_t			 linelen;
	u_int			 yy, sx = screen_size_x(s);
	u_int			 total = gd->hsize + gd->sy, count;
	uint64_t		 first, last;

	memset(sr, 0, sizeof *sr);
	cmd_search_history_bounds(gd, sr);
	if (sr->retained_first_line == 0)
		return (0);

	for (yy = 0; yy < total; yy++) {
		gl = grid_peek_line(gd, yy);
		if (gl == NULL || gl->line_number == 0)
			continue;
		first = last = gl->line_number;

		line = grid_string_cells(gd, 0, yy, sx, NULL,
		    cs->join ? 0 : GRID_STRING_TRIM_SPACES, s);
		linelen = strlen(line);
		if (cs->join) {
			while (gl->flags & GRID_LINE_WRAPPED) {
				if (yy + 1 >= total)
					break;
				yy++;
				gl = grid_peek_line(gd, yy);
				if (gl == NULL)
					break;
				if (gl->line_number != 0)
					last = gl->line_number;
				next = grid_string_cells(gd, 0, yy, sx, NULL,
				    0, s);
				line = cmd_search_history_append(line, &linelen,
				    next, strlen(next));
				free(next);
			}
		}
		count = cmd_search_history_count_matches(cs, line);
		free(line);

		if (count == 0)
			continue;
		if (sr->first_match_line == 0)
			sr->first_match_line = first;
		sr->last_match_line = last;
		sr->match_count += count;
		sr->matching_line_count++;
	}

	return (sr->match_count != 0);
}

static void
cmd_search_history_print(struct cmd *self, struct cmdq_item *item,
    struct session *s, struct winlink *wl, struct window_pane *wp,
    struct cmd_search_history_result *sr)
{
	struct args		*args = cmd_get_args(self);
	struct format_tree	*ft;
	const char		*template;
	char			*line;

	template = args_get(args, 'F');
	if (template == NULL)
		template = SEARCH_HISTORY_TEMPLATE;

	ft = format_create(cmdq_get_client(item), item, FORMAT_NONE, 0);
	format_defaults(ft, NULL, s, wl, wp);
	format_add(ft, "match_count", "%llu",
	    (unsigned long long)sr->match_count);
	format_add(ft, "matching_line_count", "%llu",
	    (unsigned long long)sr->matching_line_count);
	format_add(ft, "first_match_line", "%llu",
	    (unsigned long long)sr->first_match_line);
	format_add(ft, "last_match_line", "%llu",
	    (unsigned long long)sr->last_match_line);
	format_add(ft, "retained_first_line", "%llu",
	    (unsigned long long)sr->retained_first_line);
	format_add(ft, "retained_last_line", "%llu",
	    (unsigned long long)sr->retained_last_line);

	line = format_expand(ft, template);
	cmdq_print(item, "%s", line);
	free(line);
	format_free(ft);
}

static enum cmd_retval
cmd_search_history_exec(struct cmd *self, struct cmdq_item *item)
{
	struct args			 *args = cmd_get_args(self);
	struct cmd_search_history_state	  cs;
	struct cmd_search_history_result  sr;
	struct cmd_find_state		  fs;
	struct window_pane		 *wp;
	char				 *cause;
	long long			  n;
	u_int				  limit = 0, printed = 0;

	memset(&cs, 0, sizeof cs);
	cs.pattern = args_string(args, 0);
	cs.ignore = args_has(args, 'i');
	cs.regex = args_has(args, 'r');
	cs.join = args_has(args, 'J');
	if (cmd_search_history_compile(&cs, item) != 0)
		return (CMD_RETURN_ERROR);
	if (args_has(args, 'n')) {
		n = args_strtonum(args, 'n', 1, UINT_MAX, &cause);
		if (cause != NULL) {
			cmdq_error(item, "max-results %s", cause);
			free(cause);
			if (cs.regex)
				regfree(&cs.reg);
			return (CMD_RETURN_ERROR);
		}
		limit = n;
	}

	RB_FOREACH(wp, window_pane_tree, &all_window_panes) {
		if (limit != 0 && printed >= limit)
			break;
		if (!cmd_search_history_pane(wp, &cs, &sr))
			continue;
		if (cmd_find_from_pane(&fs, wp, 0) != 0)
			cmd_search_history_print(self, item, NULL, NULL, wp,
			    &sr);
		else {
			cmd_search_history_print(self, item, fs.s, fs.wl, wp,
			    &sr);
		}
		printed++;
	}

	if (cs.regex)
		regfree(&cs.reg);
	return (CMD_RETURN_NORMAL);
}
