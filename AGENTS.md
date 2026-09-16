# Repository instructions

Before planning or changing FocusBar, read [`requirements.md`](requirements.md) in full. Treat it as the source of truth for the product and interaction requirements.

- Keep `requirements.md` synchronized whenever a user request changes product behavior.
- Implement the requirements as written unless the user explicitly requests a change.
- Preserve the native template-based idle pill behavior, the 6:00 AM local focus-day model, and synchronization between the store, pill, status menu, management window, history, and notifications.
- Run `swift run FocusBar --self-test` after behavioral changes.
- When reinstalling, use `zsh scripts/install-app.sh`; it stops the current app before installing and relaunching it.
- Use `uv` for Python work and `pnpm` for Node.js work in this repository.
