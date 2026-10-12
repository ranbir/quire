#ifndef QUIRE_MARKDOWN_C_H
#define QUIRE_MARKDOWN_C_H

#include <cmark-gfm.h>
#include <cmark-gfm-extension_api.h>

/// Inline math: `$tex$` and `$$tex$$` on one line. Creates nodes of the two types below
/// whose TeX is returned by quire_math_tex(). Thread-safe; returns the same extension each time.
cmark_syntax_extension *quire_math_extension(void);

extern cmark_node_type QUIRE_NODE_MATH_INLINE;
extern cmark_node_type QUIRE_NODE_MATH_DISPLAY;

/// The TeX source of a math node (not NUL-terminated; see `length`).
const char *quire_math_tex(cmark_node *node, int *length);

/// Attaches GitHub's core extensions (table, strikethrough, autolink, tasklist, tagfilter
/// when `tagfilter` is non-zero) and Quire's math extension to `parser`.
void quire_attach_extensions(cmark_parser *parser, int tagfilter);

#endif
