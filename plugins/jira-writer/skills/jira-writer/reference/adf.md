# ADF Reference

Atlassian Document Format node catalog. **Prefer the markdown converter**
(`--desc-file --markdown`) over hand-building these — the converter emits valid
ADF and `adf-validate.mjs` catches mistakes client-side. Use this catalog only
for nodes the converter doesn't support (mediaSingle, custom marks, mentions).

## Document Structure

```json
{ "version": 1, "type": "doc", "content": [ /* array of block nodes */ ] }
```

## Block Nodes

**Heading:**
```json
{ "type": "heading", "attrs": { "level": 2 }, "content": [{ "type": "text", "text": "Heading Text" }] }
```

**Paragraph:**
```json
{ "type": "paragraph", "content": [{ "type": "text", "text": "Paragraph text" }] }
```

**Bullet List:**
```json
{ "type": "bulletList", "content": [{ "type": "listItem", "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Item text" }] }] }] }
```

**Ordered List:**
```json
{ "type": "orderedList", "content": [{ "type": "listItem", "content": [...] }] }
```

**Task List (Checkboxes):**
```json
{
  "type": "taskList",
  "attrs": { "localId": "unique-uuid-1" },
  "content": [
    { "type": "taskItem", "attrs": { "localId": "unique-uuid-2", "state": "TODO" }, "content": [{ "type": "text", "text": "Unchecked item" }] },
    { "type": "taskItem", "attrs": { "localId": "unique-uuid-3", "state": "DONE" }, "content": [{ "type": "text", "text": "Checked item" }] }
  ]
}
```
- `"state": "TODO"` — unchecked (markdown `- [ ]`); `"state": "DONE"` — checked (markdown `- [x]`)
- **Each `taskList` and `taskItem` requires a unique `localId` (UUID).** Generate with `uuidgen`.

**Code Block:**
```json
{ "type": "codeBlock", "attrs": { "language": "python" }, "content": [{ "type": "text", "text": "code here" }] }
```

**Media (embedded image from attachment):**
```json
{
  "type": "mediaSingle",
  "attrs": { "layout": "center" },
  "content": [{ "type": "media", "attrs": { "type": "external", "url": "https://your-domain.atlassian.net/rest/api/3/attachment/content/ATTACHMENT_ID" } }]
}
```

**Table:**
```json
{
  "type": "table",
  "attrs": { "isNumberColumnEnabled": false, "layout": "default" },
  "content": [
    { "type": "tableRow", "content": [
      { "type": "tableHeader", "attrs": {}, "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Header 1" }] }] },
      { "type": "tableHeader", "attrs": {}, "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Header 2" }] }] }
    ]},
    { "type": "tableRow", "content": [
      { "type": "tableCell", "attrs": {}, "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Cell 1" }] }] },
      { "type": "tableCell", "attrs": {}, "content": [{ "type": "paragraph", "content": [{ "type": "text", "text": "Cell 2" }] }] }
    ]}
  ]
}
```
Node types: `table` (container), `tableRow`, `tableHeader` (header cell), `tableCell` (data cell).

## Inline Marks

```json
{ "type": "text", "text": "bold",   "marks": [{ "type": "strong" }] }
{ "type": "text", "text": "italic", "marks": [{ "type": "em" }] }
{ "type": "text", "text": "code",   "marks": [{ "type": "code" }] }
{ "type": "text", "text": "link text", "marks": [{ "type": "link", "attrs": { "href": "https://..." } }] }
```

## Media Layout Options

| Layout | Behavior |
|--------|----------|
| `center` | Centered, original size (recommended) |
| `wide` | Wider than text column |
| `full-width` | Full page width |
| `align-start` | Left-aligned |
| `align-end` | Right-aligned |

## ADF Gotchas

These trip up most ADF construction. `adf-validate.mjs` (run automatically before
any ADF send) catches all of them client-side.

- **Mark exclusivity.** `code` is exclusive with `strong`, `em`, and `link`. A text
  node with `marks: [{type:"code"},{type:"strong"}]` is rejected by Jira. When
  converting markdown like `**\`compile.ts\`**`, the converter drops `strong` and
  keeps only `code`.
- **localId on taskList/taskItem.** Every `taskList` and `taskItem` needs a unique
  UUID `localId`. The converter generates these; hand-building, use `uuidgen` or
  `node -e "console.log(crypto.randomUUID())"`.
- **tableCell attrs.** `tableCell`/`tableHeader` must include an `attrs` object even
  when empty: `{"type":"tableCell","attrs":{},"content":[...]}`. Omitting it returns
  `INVALID_INPUT` with no detail.
- **204 = success.** PUTs and some DELETEs return HTTP 204 with an empty body. The
  wrapper emits `{"api":"rest","data":{"success":true}}` on 204.
- **Pre-flight your ADF.** For an opaque `INVALID_INPUT`, run
  `jira-writer validate_adf /tmp/your-adf.json` — it reports the first
  failing block index and the rule violated, without touching Jira.

## Rich Comment Example

`add_comment` accepts pre-built ADF (auto-detected: object with `type:"doc"`,
numeric `version`, array `content`):

```bash
jira-writer add_comment PROJ-123 '{
  "type": "doc",
  "version": 1,
  "content": [
    {"type": "heading", "attrs": {"level": 2}, "content": [{"type": "text", "text": "Review notes"}]},
    {"type": "bulletList", "content": [
      {"type": "listItem", "content": [
        {"type": "paragraph", "content": [{"type": "text", "text": "First point"}]}]}]}
  ]
}'
```
