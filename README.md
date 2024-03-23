## Examples
```c++
#requires AutoHotkey v2.1-alpha.8
#include <windows>

/* Switch Between Installed Keyboard Layouts. */
RShift::KeyboardLayout()

/* Switch Between Certain Keyboard Layouts. */
LShift::KeyboardLayout("sr-Cyrl-RS", "en-GB", "es-ES", "zh-Hant-TW")

/* So the LShift/ RShift will activate only on release, and it will do so only if you did not press any other key while it was held down. */
>+vkFF::return
<+vkFF::return
```
