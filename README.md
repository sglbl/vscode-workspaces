Copy the folder `vscode-workspaces@sglbl.com` to `~/.local/share/gnome-shell/extensions/`

Then restart GNOME Shell (required for new extensions to be discovered):
- **X11**: Press `Alt+F2`, type `r`, press Enter
- **Wayland**: Log out and log back in

Then enable the extension:

```bash
cp -r vscode-workspaces@sglbl.com ~/.local/share/gnome-shell/extensions/
# Restart GNOME Shell 
# X11: (Alt+F2 → r → Enter)
# Wayland: Log out and log back in
gnome-extensions enable vscode-workspaces@sglbl.com
```
