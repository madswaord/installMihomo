# Contributing

## Development Notes

- Keep changes small and scoped.
- Preserve current CLI behavior unless the change is intentional.
- Do not add dependencies unless necessary.
- Prefer POSIX-compatible shell patterns when practical.

## Before Commit

Run:

```bash
bash -n mihomo_auto_update.sh
```

If you changed install or service logic, also verify on a test machine with `systemd`.

## Commit Style

Recommended examples:

```bash
feat: add new install option
fix: handle missing service file
docs: update README
```
