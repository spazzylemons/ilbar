# ilbar

A simple classic taskbar for Wayland desktops.

## Build requirements

- GTK+ 3
- gtk-layer-shell
- libdbusmenu-gtk3 0.4
- wayland-client
- wayland-scanner
- The latest version of Zig

## Usage requirements

ilbar only runs in Wayland. Your Wayland compositor must support the layer shell
and foreign toplevel manager interfaces. You can check if your compositor
supports these by using the `wayland-info` program from within your compositor.

## Screenshot

![screenshot of ilbar running in labwc](screenshot.png)

## License

ilbar is licensed under the MIT License.
