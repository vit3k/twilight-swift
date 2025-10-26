# Keyboard Input Implementation

## Overview

The Twilight client now supports full keyboard input forwarding to the remote host. When the mouse is captured, all keyboard events (except ESC for releasing capture) are forwarded to the streaming host.

## Architecture

### Components

1. **Key Code Mapping** (`macKeyCodeToWindowsVK`)
   - Converts macOS virtual key codes to Windows virtual key codes
   - Comprehensive mapping for:
     - All letters (A-Z)
     - Numbers (0-9)
     - Function keys (F1-F12)
     - Arrow keys
     - Modifier keys (Shift, Control, Alt/Option, Command/Windows)
     - Special keys (Return, Tab, Space, Delete, Escape)
     - Editing keys (Home, End, Page Up/Down, Forward Delete)
     - Symbols and punctuation
     - Numpad keys

2. **Modifier Conversion** (`convertModifierFlags`)
   - Converts macOS modifier flags to Moonlight protocol modifiers:
     - Shift → `MODIFIER_SHIFT`
     - Control → `MODIFIER_CTRL`
     - Option/Alt → `MODIFIER_ALT`
     - Command → `MODIFIER_META` (Windows key)

3. **Event Handling**
   - Monitors three event types:
     - `.keyDown` - Key press events
     - `.keyUp` - Key release events
     - `.flagsChanged` - Modifier key state changes
   - All events are captured when mouse is in captured mode
   - Events are consumed (not passed to system) to prevent interference

### Event Flow

```
User presses key
    ↓
NSEvent captured by keyboardEventMonitor
    ↓
Convert macOS keyCode to Windows VK code
    ↓
Determine key action (DOWN/UP)
    ↓
Extract modifier flags
    ↓
Call LiSendKeyboardEvent(vkCode, action, modifiers)
    ↓
Event forwarded to streaming host
```

## Usage

### Capturing Input

When you capture the mouse (automatically on start or via Cmd+M):
1. Mouse movement and clicks are captured
2. Keyboard input is captured
3. Scroll events are captured

All input is forwarded to the remote host for gaming/streaming.

### Special Key Combinations

- **Shift+Ctrl+Option+M**: Toggles mouse capture on/off
- **Shift+Ctrl+Option+Q**: Quits the application
- **All other keys**: Forwarded to remote host (including ESC)

Note: These special combinations use all three modifiers to avoid conflicts with game shortcuts.

### Modifier Key Handling

The implementation properly handles modifier keys in two ways:

1. **As standalone keys**: When you press/release Shift, Ctrl, Alt, or Command alone, they generate appropriate key events
2. **As modifiers**: When held with other keys, the modifier flags are sent along with the key event

Example: Pressing "Ctrl+C" generates:
- Control key DOWN event with MODIFIER_CTRL
- C key DOWN event with MODIFIER_CTRL
- C key UP event with MODIFIER_CTRL
- Control key UP event (no modifier)

## Supported Key Mappings

### Letters and Numbers
- Full support for A-Z and 0-9 keys
- Numpad 0-9 mapped separately

### Function Keys
- F1 through F12 fully supported

### Navigation Keys
- Arrow keys (Up, Down, Left, Right)
- Home, End
- Page Up, Page Down

### Editing Keys
- Backspace (Delete key)
- Forward Delete
- Return/Enter
- Tab
- Space
- Escape (for releasing capture)

### Modifier Keys
- Left/Right Shift → Windows Shift
- Left/Right Control → Windows Control
- Left/Right Option → Windows Alt
- Left/Right Command → Windows Meta/Windows key

### Symbols
- All standard US keyboard symbols
- Brackets, quotes, semicolon, comma, period, slash
- Minus, equals, backslash, grave/tilde

### Numpad
- Numbers 0-9
- Operators: +, -, *, /
- Decimal point
- Num Lock

## Implementation Details

### Thread Safety

- Event monitors are created and destroyed on the main thread
- Uses `@MainActor` annotations for thread safety
- Weak self reference in keyboard monitor to prevent retain cycles

### Performance

- Direct key code conversion using switch statement (O(1) lookup)
- Minimal processing per key event
- Events consumed immediately to prevent system interference

### Compatibility

The keyboard mapping is designed to work with:
- Windows hosts (Sunshine/Moonlight protocol)
- Standard US keyboard layout
- International keyboards (may require additional mappings)

## Future Enhancements

Possible improvements for future versions:

1. **International Keyboard Support**
   - Add mappings for non-US keyboard layouts
   - Support for international characters

2. **Key Repeat Handling**
   - Option to control key repeat behavior
   - Configurable repeat rate

3. **Key Remapping**
   - Allow users to remap keys
   - Custom key binding profiles

4. **On-Screen Keyboard Indicator**
   - Visual feedback for active modifiers
   - Caps Lock indicator

5. **Text Input Method Support**
   - Support for IME (Input Method Editors)
   - International text input

## Technical Reference

### Moonlight Protocol Constants

```c
#define KEY_ACTION_DOWN 0x03
#define KEY_ACTION_UP 0x04
#define MODIFIER_SHIFT 0x01
#define MODIFIER_CTRL 0x02
#define MODIFIER_ALT 0x04
#define MODIFIER_META 0x08
```

### Function Signature

```c
int LiSendKeyboardEvent(short keyCode, char keyAction, char modifiers);
```

Parameters:
- `keyCode`: Windows virtual key code (VK_*)
- `keyAction`: KEY_ACTION_DOWN or KEY_ACTION_UP
- `modifiers`: Bitfield of MODIFIER_* flags

## Testing

To test keyboard input:
1. Start streaming session
2. Mouse will be automatically captured
3. Type keys - they should appear on remote host
4. Press Shift+Ctrl+Option+M to toggle capture
5. Press Shift+Ctrl+Option+Q to quit

Common test cases:
- Type regular text → Should appear in remote text editor
- Press Ctrl+C/V → Should copy/paste on remote host
- Use arrow keys → Should navigate in remote applications
- Press function keys → Should trigger appropriate actions
- Try game shortcuts → Should work in remote games
- Press ESC → Should now be sent to remote host (no longer releases capture)

## Troubleshooting

### Keys not responding
- Ensure mouse is captured (see status message)
- Check that keyboard monitor is active
- Verify connection to streaming host

### Wrong characters appearing
- May be due to keyboard layout mismatch
- Host and client should use same layout
- International layouts may need custom mapping

### Modifier keys stuck
- Release and recapture mouse (ESC + Cmd+M)
- May occur if focus is lost during key press

### Special shortcuts not working
- Ensure you're pressing all three modifiers (Shift+Ctrl+Option) plus M or Q
- Check if shortcuts conflict with system-wide macOS shortcuts
- Look for conflicts with other key monitors
