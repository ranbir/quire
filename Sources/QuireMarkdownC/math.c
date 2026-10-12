// Inline math for cmark-gfm, following pandoc's tex_math_dollars rules:
//   $…$   the opening $ is not preceded by a letter or digit and is followed by a
//         non-space; the first unescaped $ after it closes, and must follow a non-space
//         and not be followed by a digit (so "$5 and $10" stays text).
//   $$…$$ display math within a line.
// Math never crosses a line break or a backtick (code spans take precedence); `$$` blocks on their own lines are turned into
// ~~~math fences before parsing (see MarkdownDocument).

#include <ctype.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include "QuireMarkdownC.h"
#include <cmark-gfm-core-extensions.h>
#include <houdini.h>
#include <node.h>
#include <parser.h>
#include <render.h>

cmark_node_type QUIRE_NODE_MATH_INLINE;
cmark_node_type QUIRE_NODE_MATH_DISPLAY;

static cmark_syntax_extension *math_ext;
static pthread_once_t math_once = PTHREAD_ONCE_INIT;

static int is_space(unsigned char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }
static int is_eol(unsigned char c) { return c == '\n' || c == '\r'; }

static cmark_node *match(cmark_syntax_extension *self, cmark_parser *parser, cmark_node *parent,
                         unsigned char character, cmark_inline_parser *inline_parser) {
  if (character != '$') return NULL;
  cmark_chunk *chunk = cmark_inline_parser_get_chunk(inline_parser);
  const unsigned char *s = chunk->data;
  int len = chunk->len;
  int pos = cmark_inline_parser_get_offset(inline_parser);
  if (pos > 0 && s[pos - 1] == '$') return NULL;

  int display = pos + 1 < len && s[pos + 1] == '$';
  int delim = display ? 2 : 1;
  int start = pos + delim;
  int end = -1;

  if (display) {
    if (start < len && s[start] == '$') return NULL;
    for (int i = start; i + 1 < len && !is_eol(s[i]) && s[i] != '`'; i++) {
      if (s[i] == '\\') { i++; continue; }
      if (s[i] == '$') {
        if (s[i + 1] == '$') end = i;
        break;
      }
    }
    if (end <= start) return NULL;
  } else {
    if (pos > 0 && (isalnum(s[pos - 1]) || s[pos - 1] == '_')) return NULL;
    if (start >= len || is_space(s[start])) return NULL;
    for (int i = start; i < len && !is_eol(s[i]) && s[i] != '`'; i++) {
      if (s[i] == '\\') { i++; continue; }
      if (s[i] == '$') {
        if (!is_space(s[i - 1]) && !(i + 1 < len && (isdigit(s[i + 1]) || s[i + 1] == '$'))) end = i;
        break;
      }
    }
    if (end < 0) return NULL;
  }

  cmark_node *node = cmark_node_new_with_mem_and_ext(display ? QUIRE_NODE_MATH_DISPLAY : QUIRE_NODE_MATH_INLINE,
                                                     parser->mem, self);
  cmark_strbuf_put(&node->content, s + start, end - start);
  int line = cmark_inline_parser_get_line(inline_parser);
  int column = cmark_inline_parser_get_column(inline_parser);
  node->start_line = node->end_line = line;
  node->start_column = column;
  node->end_column = column + (end + delim - pos) - 1;
  cmark_inline_parser_set_offset(inline_parser, end + delim);
  return node;
}

const char *quire_math_tex(cmark_node *node, int *length) {
  *length = (int)node->content.size;
  return (const char *)node->content.ptr;
}

static const char *get_type_string(cmark_syntax_extension *ext, cmark_node *node) {
  return node->type == QUIRE_NODE_MATH_DISPLAY ? "math_display" : "math_inline";
}

static int can_contain(cmark_syntax_extension *ext, cmark_node *node, cmark_node_type child) { return 0; }

static void html_render(cmark_syntax_extension *ext, cmark_html_renderer *renderer, cmark_node *node,
                        cmark_event_type ev, int options) {
  if (ev != CMARK_EVENT_ENTER) return;
  cmark_strbuf *html = renderer->html;
  cmark_strbuf_puts(html, node->type == QUIRE_NODE_MATH_DISPLAY ? "<span class=\"math math-display\""
                                                                : "<span class=\"math math-inline\"");
  if (options & CMARK_OPT_SOURCEPOS) {
    char buf[96];
    snprintf(buf, sizeof buf, " data-sourcepos=\"%d:%d-%d:%d\"", node->start_line, node->start_column,
             node->end_line, node->end_column);
    cmark_strbuf_puts(html, buf);
  }
  cmark_strbuf_putc(html, '>');
  houdini_escape_html0(html, node->content.ptr, node->content.size, 0);
  cmark_strbuf_puts(html, "</span>");
}

static void literal_render(cmark_syntax_extension *ext, cmark_renderer *renderer, cmark_node *node,
                           cmark_event_type ev, int options) {
  if (ev != CMARK_EVENT_ENTER) return;
  const char *delim = node->type == QUIRE_NODE_MATH_DISPLAY ? "$$" : "$";
  renderer->out(renderer, node, delim, false, LITERAL);
  cmark_strbuf_put(renderer->buffer, node->content.ptr, node->content.size);
  renderer->out(renderer, node, delim, false, LITERAL);
}

static void plaintext_render(cmark_syntax_extension *ext, cmark_renderer *renderer, cmark_node *node,
                             cmark_event_type ev, int options) {
  if (ev != CMARK_EVENT_ENTER) return;
  cmark_strbuf_put(renderer->buffer, node->content.ptr, node->content.size);
}

static void make_math(void) {
  cmark_syntax_extension *ext = cmark_syntax_extension_new("quire_math");
  cmark_syntax_extension_set_get_type_string_func(ext, get_type_string);
  cmark_syntax_extension_set_can_contain_func(ext, can_contain);
  cmark_syntax_extension_set_html_render_func(ext, html_render);
  cmark_syntax_extension_set_commonmark_render_func(ext, literal_render);
  cmark_syntax_extension_set_plaintext_render_func(ext, plaintext_render);
  cmark_syntax_extension_set_match_inline_func(ext, match);
  QUIRE_NODE_MATH_INLINE = cmark_syntax_extension_add_node(1);
  QUIRE_NODE_MATH_DISPLAY = cmark_syntax_extension_add_node(1);
  cmark_llist *chars = cmark_llist_append(cmark_get_default_mem_allocator(), NULL, (void *)'$');
  cmark_syntax_extension_set_special_inline_chars(ext, chars);
  cmark_gfm_core_extensions_ensure_registered();
  math_ext = ext;
}

cmark_syntax_extension *quire_math_extension(void) {
  pthread_once(&math_once, make_math);
  return math_ext;
}

void quire_attach_extensions(cmark_parser *parser, int tagfilter) {
  quire_math_extension();
  const char *names[] = {"table", "strikethrough", "autolink", "tasklist", "tagfilter"};
  for (int i = 0; i < 5; i++) {
    if (i == 4 && !tagfilter) continue;
    cmark_syntax_extension *ext = cmark_find_syntax_extension(names[i]);
    if (ext) cmark_parser_attach_syntax_extension(parser, ext);
  }
  cmark_parser_attach_syntax_extension(parser, math_ext);
}
