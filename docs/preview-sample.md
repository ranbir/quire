# Preview sample

A tour of what the live preview (`⌥⌘P`) renders: **diagrams**, *math* and highlighted code.

## Architecture

```mermaid
flowchart LR
    subgraph App["Quire.app"]
        Editor[Editor view] -->|text| Preview[Preview window]
        Preview --> WebKit[(WKWebView)]
    end
    subgraph Core["QuireCore"]
        MD[Markdown renderer]
    end
    Editor --> MD
    MD -->|HTML| Preview
    WebKit --> Libs{{Mermaid · KaTeX · highlight.js}}
```

## Live update

```mermaid
sequenceDiagram
    participant U as You
    participant E as Editor
    participant P as Preview
    U->>E: type
    E->>P: scheduleUpdate() after 0.3 s
    P->>P: quireUpdate(body)
    Note right of P: scroll and diagrams kept
```

## Math

Euler's identity $e^{i\pi} + 1 = 0$ inline, and a display equation:

$$
\int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
$$

Prices like $5 and $10 stay as text.

## Code

```swift
struct Rendered {
    var page: String
    var body: String? = nil   // swapped in place when the shell matches
}
```

```python
def fib(n: int) -> int:
    return n if n < 2 else fib(n - 1) + fib(n - 2)
```

```
+--------+      +---------+
| Editor | ---> | Preview |
+--------+      +---------+
```

| Feature | Library | Loaded |
|:--|:--|:--|
| Code | highlight.js | always |
| Math | KaTeX | when the page has math |
| Diagrams | Mermaid | when the page has diagrams |
