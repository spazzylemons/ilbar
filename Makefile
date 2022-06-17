SRCDIR   := src
BUILDDIR := build

TARGET := $(BUILDDIR)/ilbar

CFILES := $(SRCDIR)/client.c $(SRCDIR)/main.c
OFILES := $(patsubst $(SRCDIR)/%.c,$(BUILDDIR)/%.o,$(CFILES))
DFILES := $(OFILES:.o=.d)

XDG_PROTOCOL   := /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
LAYER_PROTOCOL := lib/wlr-layer-shell-unstable-v1.xml

XDG_PROTO_H := $(BUILDDIR)/xdg-shell.h
XDG_PROTO_C := $(BUILDDIR)/xdg-shell.c

LAYER_PROTO_H := $(BUILDDIR)/layer-shell.h
LAYER_PROTO_C := $(BUILDDIR)/layer-shell.c

CFLAGS := -g -Wall -Wextra -I$(BUILDDIR) \
	$(shell pkg-config --cflags wayland-client)

LDFLAGS := $(shell pkg-config --libs wayland-client)

$(TARGET): $(OFILES) $(XDG_PROTO_C) $(LAYER_PROTO_C)
	$(CC) $(CFLAGS) $(OFILES) $(XDG_PROTO_C) $(LAYER_PROTO_C) -o $@ $(LDFLAGS)

$(OFILES): $(XDG_PROTO_H) $(LAYER_PROTO_H)

$(XDG_PROTO_H):
	mkdir -p $(BUILDDIR)
	wayland-scanner client-header < $(XDG_PROTOCOL) > $(XDG_PROTO_H)

$(XDG_PROTO_C):
	mkdir -p $(BUILDDIR)
	wayland-scanner private-code < $(XDG_PROTOCOL) > $(XDG_PROTO_C)

$(LAYER_PROTO_H):
	mkdir -p $(BUILDDIR)
	wayland-scanner client-header < $(LAYER_PROTOCOL) > $(LAYER_PROTO_H)

$(LAYER_PROTO_C):
	mkdir -p $(BUILDDIR)
	wayland-scanner private-code < $(LAYER_PROTOCOL) > $(LAYER_PROTO_C)

$(BUILDDIR)/%.o: $(SRCDIR)/%.c
	mkdir -p $(BUILDDIR)
	$(CC) -fsyntax-only $(CFLAGS) -MMD -MF $(BUILDDIR)/$*.d $<
	$(CC) $(CFLAGS) $< -c -o $@

.PHONY: clean run

clean:
	-rm -r $(BUILDDIR)

run: $(TARGET)
	./$(TARGET)

-include $(DFILES)
