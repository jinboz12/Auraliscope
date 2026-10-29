#pragma once

// The plugin window shared by the VST3 and AU wrappers: the source name (editable, saved in the project), the
// connection to Auraliscope LABS, what the stream carries, and this insert's own measurement (with Reset and
// Pause). It reads the core's status; closing it changes nothing about the analysis or what is sent.

#include <functional>
#include <memory>

namespace abr {

class BridgeCore;

constexpr int kEditorWidth = 440;
constexpr int kEditorHeight = 622;

// Returns a retained NSView (as void *). `nameEdited` runs on the main thread after the user changes the name,
// so the wrapper can mark the project as modified.
void *createEditorView(std::shared_ptr<BridgeCore> core, std::function<void()> nameEdited, const char *formatLabel);
// Adds the view to a host-provided NSView.
void attachEditorView(void *view, void *parent);
// Stops updates, removes the view from its parent and releases it.
void destroyEditorView(void *view);

}  // namespace abr
