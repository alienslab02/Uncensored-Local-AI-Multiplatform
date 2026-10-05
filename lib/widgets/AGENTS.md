# lib/widgets/ — Reusable UI components

## Purpose

Composable widgets: chat bubbles, sidebar, model cards, typing indicator.

## Files that belong here

- Stateless/stateful widgets shared across screens
- No GetX service initialization here (find controllers if needed, sparingly)

## Rules

1. Prefer pure props-in rendering; avoid fetching services unless the widget is app-shell specific.
2. Match spacing/typography of sibling widgets.
3. Markdown/chat rendering stays consistent with `chat_bubble.dart` behavior.
4. If a widget grows screen-sized, promote it to `lib/screens/` or split.
