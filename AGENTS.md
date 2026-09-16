# Repository instructions

Before planning or changing FocusBar, read [`requirements.md`](requirements.md) in full. Treat it as the source of truth for the resolved product and interaction requirements from the original design conversation.

- If a new user request conflicts with `requirements.md`, follow the newer explicit request and update `requirements.md` in the same change so it remains accurate.
- Do not revive superseded behavior merely because it appears in older code or Git history.
- Preserve the native template-based idle pill behavior, the 6:00 AM local focus-day model, and synchronization between the store, pill, status menu, management window, history, and notifications.
- Run `swift run FocusBar --self-test` after behavioral changes.
- When reinstalling, use `zsh scripts/install-app.sh`; it stops the current app before installing and relaunching it.
- Use `uv` for Python work and `pnpm` for Node.js work in this repository.
