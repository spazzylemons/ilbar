LIBDIR   := lib
SRCDIR   := src
BUILDDIR := build

TARGET := $(BUILDDIR)/ilbar

CFILES := $(SRCDIR)/client.c $(SRCDIR)/main.c $(SRCDIR)/render.c
OFILES := $(patsubst $(SRCDIR)/%.c,$(BUILDDIR)/%.o,$(CFILES))
DFILES := $(OFILES:.o=.d)

XDG_PROTOCOL     := /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
FOREIGN_PROTOCOL := $(LIBDIR)/wlr-foreign-toplevel-management-unstable-v1.xml
LAYER_PROTOCOL   := $(LIBDIR)/wlr-layer-shell-unstable-v1.xml

XDG_PROTO_H := $(BUILDDIR)/xdg-shell.h
XDG_PROTO_C := $(BUILDDIR)/xdg-shell.c

FOREIGN_PROTO_H := $(BUILDDIR)/wlr-foreign.h
FOREIGN_PROTO_C := $(BUILDDIR)/wlr-foreign.c

LAYER_PROTO_H := $(BUILDDIR)/layer-shell.h
LAYER_PROTO_C := $(BUILDDIR)/layer-shell.c

LOG_C := $(LIBDIR)/log.c

CFLAGS := -g -Wall -Wextra -I$(BUILDDIR) -I$(LIBDIR) \
	$(shell pkg-config --cflags cairo) \
	$(shell pkg-config --cflags wayland-client)

LDFLAGS := \
	$(shell pkg-config --libs cairo) \
	$(shell pkg-config --libs wayland-client)

$(TARGET): $(OFILES) $(XDG_PROTO_C) $(FOREIGN_PROTO_C) $(LAYER_PROTO_C)
	$(CC) $(CFLAGS) $(OFILES) \
		$(XDG_PROTO_C) $(LAYER_PROTO_C) $(FOREIGN_PROTO_C) $(LOG_C) \
		-o $@ $(LDFLAGS)

$(OFILES): $(XDG_PROTO_H) $(FOREIGN_PROTO_H) $(LAYER_PROTO_H)

$(XDG_PROTO_H):
	mkdir -p $(BUILDDIR)
	wayland-scanner client-header < $(XDG_PROTOCOL) > $(XDG_PROTO_H)

$(XDG_PROTO_C):
	mkdir -p $(BUILDDIR)
	wayland-scanner private-code < $(XDG_PROTOCOL) > $(XDG_PROTO_C)

$(FOREIGN_PROTO_H):
	mkdir -p $(BUILDDIR)
	wayland-scanner client-header < $(FOREIGN_PROTOCOL) > $(FOREIGN_PROTO_H)

$(FOREIGN_PROTO_C):
	mkdir -p $(BUILDDIR)
	wayland-scanner private-code < $(FOREIGN_PROTOCOL) > $(FOREIGN_PROTO_C)

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
