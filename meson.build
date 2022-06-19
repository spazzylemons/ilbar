project(
  'ilbar',
  'c',
  version: '0.1',
  default_options: ['warning_level=3'],
)

add_project_arguments(
  [
    '-D_POSIX_C_SOURCE=200809L',
    '-DLOG_USE_COLOR',
  ],
  language: 'c',
)

wayland_protocols = dependency('wayland-protocols')
wayland_scanner = dependency('wayland-scanner')

protocols_path = wayland_protocols.get_pkgconfig_variable('pkgdatadir')
scanner_bin = wayland_scanner.get_pkgconfig_variable('wayland_scanner')

protocol_xml = [
  protocols_path / 'stable/xdg-shell/xdg-shell.xml',
  'lib/wlr-foreign-toplevel-management-unstable-v1.xml',
  'lib/wlr-layer-shell-unstable-v1.xml',
]

protocols_cfiles = []
protocols_hfiles = []

foreach protocol : protocol_xml
  protocols_cfiles += custom_target(
    protocol.underscorify() + '_c',
    input: protocol,
    output: '@BASENAME@-protocol.c',
    command: [scanner_bin, 'private-code', '@INPUT@', '@OUTPUT@'],
  )

  protocols_hfiles += custom_target(
    protocol.underscorify() + '_h',
    input: protocol,
    output: '@BASENAME@-protocol.h',
    command: [scanner_bin, 'client-header', '@INPUT@', '@OUTPUT@'],
  )
endforeach

protocols = declare_dependency(
  link_with: static_library('protocols', [protocols_cfiles, protocols_hfiles]),
  sources: protocols_hfiles,
)

cj_lib = custom_target(
  'cj.c',
  output: 'cj.o',
  command: [
    '/bin/sh',
    '-c',
    'make -C @SOURCE_ROOT@/cj && cp @SOURCE_ROOT@/cj/cj.o @OUTPUT@',
  ],
)

cj = declare_dependency(
  link_with: static_library('cj', cj_lib),
)

executable(
  'ilbar',

  sources: files(
    'src/client.c',
    'src/config.c',
    'src/gui.c',
    'src/main.c',
    'lib/log.c',
  ),

  include_directories: [
    'cj',
    'lib',
  ],

  dependencies: [
    dependency('wayland-client'),
    dependency('cairo'),
    protocols,
    cj,
  ],

  install: true,
)
