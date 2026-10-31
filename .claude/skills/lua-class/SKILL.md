---
name: lua-class
description:
  Use when creating new lua classes or adding fields or methods to existing lua
  classes. It gives guide lines on how to work with Lua classes and style guides
  that must be followed in this project
---

# Lua Class Pattern

**Basic class structure:**

```lua
--- @class Animal
local Animal = {}
Animal.__index = Animal

function Animal:new()
    self = setmetatable({}, self)
    return self
end

function Animal:move()
    print("Animal moves")
end
```

**Key points:**

- Set `__index` to `self` for inheritance
- Use `setmetatable` to create instances
- Return the instance from constructor

**Method definition syntax:**

- `function Class:method()` - Instance method, receives `self` implicitly
  - Called as: `instance:method()` or `instance.method(instance)`
  - Use for methods that need access to instance state

- `function Class.method()` - Module function, static, does NOT receive `self`
  - Called as: `Class.method()` or `instance.method()` (both work, but no
    `self`)
  - Use for utility functions, constructors, or static helpers

## Inheritance Pattern

**Class setup (module-level):**

```lua
local Parent = {}
Parent.__index = Parent

--- @class Child : Parent
local Child = setmetatable({}, { __index = Parent })
Child.__index = Child
```

**Constructor with parent initialization:**

```lua
function Parent:new(name)
    local instance = {
        name = name,
        parent_state = {}
    }
    return setmetatable(instance, self)
end

function Child:new(name, extra)
    local instance = Parent.new(self, name)
    instance.child_state = extra
    return instance
end
```

**Critical rules:**

- **Pass `self` to the parent constructor:** `Parent.new(self, ...)`, so
  methods it calls resolve on the child class
- **Inheritance chain:** `instance → Child → Parent`

**Calling parent methods:**

```lua
function Child:move()
    Parent.move(self)  -- Explicit parent method call
    print("Child-specific movement")
end
```

## Class Design Guidelines: creating and modifying

- **Minimize class properties** - Only include properties that:
  - Are accessed by external code (other modules/classes)
  - Are part of the public API
  - Need to be accessed by subclasses

- **Use visibility prefixes for encapsulation** - Control what external code can
  access:

  **Visibility levels (configured in `.luarc.json`):**
  - `_*`: **Private** - Hidden from external consumers (applies to class
    methods/fields ONLY)
  - `__*`: **Protected** - Visible to subclasses
  - No prefix: **Public** - Visible everywhere

  **IMPORTANT:** Module-level local functions and variables do NOT need `_`
  prefix:
  - ✅ `local function helper()` - correct (already private by `local` scope)
  - ❌ `local function _helper()` - incorrect (redundant `_` prefix)
  - ✅ `local config = {}` - correct
  - ❌ `local _config = {}` - incorrect (redundant `_` prefix)
  - ✅ `function MyClass:_private_method()` - correct (class method needs `_`)
  - ✅ `@field _private_field` - correct (class field needs `_`)

  ```lua
  -- ❌ Bad: Unnecessary public exposure of `counter` property, not used externally
  --- @class MyClass
  --- @field counter number
  local MyClass = {}
  MyClass.__index = MyClass

  function MyClass:new()
      return setmetatable({ counter = 0 }, self)
  end

  -- ✅ Good: Proper visibility control
  --- @class MyClass
  local MyClass = {}
  MyClass.__index = MyClass

  function MyClass:new()
      return setmetatable({
        -- Counter is internal state, not exposed publicly
        _counter = 0
      }, self)
  end

  --- @protected
  function MyClass:__protected_method()
      self._counter = self._counter + 1
  end

  --- Module-level helper functions (no underscore prefix needed)
  local function format_value(val)
      return tostring(val)
  end

  --- @class Child : MyClass
  function Child:use_parent_state()
      self:__protected_method()
  end
  ```

  **Note:** The `@private` annotation is NOT necessary for private class methods
  - LuaLS infers privacy from the `_` prefix automatically
  - Only use `@protected` for protected methods (`__*`, luals limitation)

- **Document intent with LuaCATS** - Use visibility annotations:

  ```lua
  --- @class MyClass
  --- @field public_field string Public API
  --- @field __protected_field table For subclasses
  --- @field _private_field number Internal only
  ```

- **Regular cleanup** - When adding new code, review class definitions and
  remove:
  - Unused properties
  - Properties that were needed during development but are no longer used
  - Properties that could be local variables instead
