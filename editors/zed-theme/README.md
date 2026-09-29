# Fun Web theme for Zed

The Fun website palette as two Zed themes: **Fun Web** (dark) and **Fun Web Light**.

Pick one from the theme selector (`theme selector: toggle`) after installing. The colors match the themes shipped for VS Code, Sublime, Vim, Emacs and JetBrains.

The base syntax and UI colors are generated from `editors/vscode/themes`, so a palette change there should be mirrored here. Zed has UI surfaces VS Code doesn't expose as theme colors, diagnostics (error/warning/hint/info), git status, the scrollbar and minimap, and a few others; those are set directly in `themes/fun-web.json`, built from the same palette and checked against WCAG AA contrast (4.5:1) on their own background.
