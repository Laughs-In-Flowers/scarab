ecs = {}

-- Local versions of standard lua functions
local tinsert = table.insert
local tremove = table.remove
local tsort = table.sort
local setmetatable = setmetatable
local type = type
local select = select

-- Local versions of the library functions
local ecs_manageEntities
local ecs_manageSystems
local ecs_addEntity
local ecs_addSystem
local ecs_add
local ecs_removeEntity
local ecs_removeSystem

--- Filter functions.
-- A Filter is a function that selects which Entities apply to a System.
-- Filters take two parameters, the System and the Entity, and return a boolean
-- value indicating if the Entity should be processed by the System. A truthy
-- value includes the entity, while a falsey (nil or false) value excludes the
-- entity.
--
-- Filters must be added to Systems by setting the `filter` field of the System.
-- Filter's returned by ecs-ecs's Filter functions are immutable and can be
-- used by multiple Systems.
--
--    local f1 = ecs.requireAll("position", "velocity", "size")
--    local f2 = ecs.requireAny("position", "velocity", "size")
--
--    local e1 = {
--        position = {2, 3},
--        velocity = {3, 3},
--        size = {4, 4}
--    }
--
--    local entity2 = {
--        position = {4, 5},
--        size = {4, 4}
--    }
--
--    local e3 = {
--        position = {2, 3},
--        velocity = {3, 3}
--    }
--
--    print(f1(nil, e1), f1(nil, e2), f1(nil, e3)) -- prints true, false, false
--    print(f2(nil, e1), f2(nil, e2), f2(nil, e3)) -- prints true, true, true
--
-- Filters can also be passed as arguments to other Filter constructors. This is
-- a powerful way to create complex, custom Filters that select a very specific
-- set of Entities.
--
--    -- Selects Entities with an "image" Component, but not Entities with a
--    -- "Player" or "Enemy" Component.
--    filter = ecs.requireAll("image", ecs.rejectAny("Player", "Enemy"))
--
-- @section Filter

-- A helper function to compile filters.
local filterJoin

-- A helper function to filters from string
local filterBuildString

do
    local loadstring = loadstring or load
    local function getchr(c)
        return "\\" .. c:byte()
    end
    local function make_safe(text)
        return ("%q"):format(text):gsub('\n', 'n'):gsub("[\128-\255]", getchr)
    end

    local function filterJoinRaw(prefix, seperator, ...)
        local accum = {}
        local build = {}
        for i = 1, select('#', ...) do
            local item = select(i, ...)
            if type(item) == 'string' then
                accum[#accum + 1] = ("(e[%s] ~= nil)"):format(make_safe(item))
            elseif type(item) == 'function' then
                build[#build + 1] = ('local subfilter_%d_ = select(%d, ...)')
                    :format(i, i)
                accum[#accum + 1] = ('(subfilter_%d_(system, e))'):format(i)
            else
                error 'Filter token must be a string or a filter function.'
            end
        end
        local source = ('%s\nreturn function(system, e) return %s(%s) end')
            :format(
                table.concat(build, '\n'),
                prefix,
                table.concat(accum, seperator))
        local loader, err = loadstring(source)
        if err then error(err) end
        return loader(...)
    end

    function filterJoin(...)
        local state, value = pcall(filterJoinRaw, ...)
        if state then return value else return nil, value end
    end

    local function buildPart(str)
        local accum = {}
        local subParts = {}
        str = str:gsub('%b()', function(p)
            subParts[#subParts + 1] = buildPart(p:sub(2, -2))
            return ('\255%d'):format(#subParts)
        end)
        for invert, part, sep in str:gmatch('(%!?)([^%|%&%!]+)([%|%&]?)') do
            if part:match('^\255%d+$') then
                local partIndex = tonumber(part:match(part:sub(2)))
                accum[#accum + 1] = ('%s(%s)')
                    :format(invert == '' and '' or 'not', subParts[partIndex])
            else
                accum[#accum + 1] = ("(e[%s] %s nil)")
                    :format(make_safe(part), invert == '' and '~=' or '==')
            end
            if sep ~= '' then
                accum[#accum + 1] = (sep == '|' and ' or ' or ' and ')
            end
        end
        return table.concat(accum)
    end

    function filterBuildString(str)
        local source = ("return function(_, e) return %s end")
            :format(buildPart(str))
        local loader, err = loadstring(source)
        if err then
            error(err)
        end
        return loader()
    end
end

--- Makes a Filter that selects Entities with all specified Components and
-- Filters.
function ecs.requireAll(...)
    return filterJoin('', ' and ', ...)
end

--- Makes a Filter that selects Entities with at least one of the specified
-- Components and Filters.
function ecs.requireAny(...)
    return filterJoin('', ' or ', ...)
end

--- Makes a Filter that rejects Entities with all specified Components and
-- Filters, and selects all other Entities.
function ecs.rejectAll(...)
    return filterJoin('not', ' and ', ...)
end

--- Makes a Filter that rejects Entities with at least one of the specified
-- Components and Filters, and selects all other Entities.
function ecs.rejectAny(...)
    return filterJoin('not', ' or ', ...)
end

--- Makes a Filter from a string. Syntax of `pattern` is as follows.
--
--   * Tokens are alphanumeric strings including underscores.
--   * Tokens can be separated by |, &, or surrounded by parentheses.
--   * Tokens can be prefixed with !, and are then inverted.
--
-- Examples are best:
--    'a|b|c' - Matches entities with an 'a' OR 'b' OR 'c'.
--    'a&!b&c' - Matches entities with an 'a' AND NOT 'b' AND 'c'.
--    'a|(b&c&d)|e - Matches 'a' OR ('b' AND 'c' AND 'd') OR 'e'
-- @param pattern
function ecs.filter(pattern)
    local state, value = pcall(filterBuildString, pattern)
    if state then return value else return nil, value end
end

--- System functions.
-- A System is a wrapper around function callbacks for manipulating Entities.
-- Systems are implemented as tables that contain at least one method;
-- an update function that takes parameters like so:
--
--   * `function system:update(dt)`.
--
-- There are also a few other optional callbacks:
--
--   * `function system:filter(entity)` - Returns true if this System should
-- include this Entity, otherwise should return false. If this isn't specified,
-- no Entities are included in the System.
--   * `function system:onAdd(entity)` - Called when an Entity is added to the
-- System.
--   * `function system:onRemove(entity)` - Called when an Entity is removed
-- from the System.
--   * `function system:onModify(dt)` - Called when the System is modified by
-- adding or removing Entities from the System.
--   * `function system:onAddToWorld(world)` - Called when the System is added
-- to the World, before any entities are added to the system.
--   * `function system:onRemoveFromWorld(world)` - Called when the System is
-- removed from the world, after all Entities are removed from the System.
--   * `function system:preWrap(dt)` - Called on each system before update is
-- called on any system.
--   * `function system:postWrap(dt)` - Called on each system in reverse order
-- after update is called on each system. The idea behind `preWrap` and
-- `postWrap` is to allow for systems that modify the behavior of other systems.
-- Say there is a DrawingSystem, which draws sprites to the screen, and a
-- PostProcessingSystem, that adds some blur and bloom effects. In the preWrap
-- method of the PostProcessingSystem, the System could set the drawing target
-- for the DrawingSystem to a special buffer instead the screen. In the postWrap
-- method, the PostProcessingSystem could then modify the buffer and render it
-- to the screen. In this setup, the PostProcessingSystem would be added to the
-- World after the drawingSystem (A similar but less flexible behavior could
-- be accomplished with a single custom update function in the DrawingSystem).
--
-- For Filters, it is convenient to use `ecs.requireAll` or `ecs.requireAny`,
-- but one can write their own filters as well. Set the Filter of a System like
-- so:
--    system.filter = ecs.requireAll("a", "b", "c")
-- or
--    function system:filter(entity)
--        return entity.myRequiredComponentName ~= nil
--    end
--
-- All Systems also have a few important fields that are initialized when the
-- system is added to the World. A few are important, and few should be less
-- commonly used.
--
--   * The `world` field points to the World that the System belongs to. Useful
-- for adding and removing Entities from the world dynamically via the System.
--   * The `active` flag is whether or not the System is updated automatically.
-- Inactive Systems should be updated manually or not at all via
-- `system:update(dt)`. Defaults to true.
--   * The `entities` field is an ordered list of Entities in the System. This
-- list can be used to quickly iterate through all Entities in a System.
--   * The `interval` field is an optional field that makes Systems update at
-- certain intervals using buffered time, regardless of World update frequency.
-- For example, to make a System update once a second, set the System's interval
-- to 1.
--   * The `index` field is the System's index in the World. Lower indexed
-- Systems are processed before higher indices. The `index` is a read only
-- field; to set the `index`, use `ecs.setSystemIndex(world, system)`.
--   * The `indices` field is a table of Entity keys to their indices in the
-- `entities` list. Most Systems can ignore this.
--   * The `modified` flag is an indicator if the System has been modified in
-- the last update. If so, the `onModify` callback will be called on the System
-- in the next update, if it has one. This is usually managed by ecs-ecs, so
-- users should mostly ignore this, too.
--
-- There is another option to (hopefully) increase performance in systems that
-- have items added to or removed from them often, and have lots of entities in
-- them.  Setting the `nocache` field of the system might improve performance.
-- It is still experimental. There are some restriction to systems without
-- caching, however.
--
--   * There is no `entities` table.
--   * Callbacks such onAdd, onRemove, and onModify will never be called
--   * Noncached systems cannot be sorted (There is no entities list to sort).
--
-- @section System

-- Use an empty table as a key for identifying Systems. Any table that contains
-- this key is considered a System rather than an Entity.
local systemTableKey = { "SYSTEM_TABLE_KEY" }

-- Checks if a table is a System.
local function isSystem(table)
    return table[systemTableKey]
end

-- Update function for all Processing Systems.
local function processingSystemUpdate(system, dt)
    local preProcess = system.preProcess
    local process = system.process
    local postProcess = system.postProcess

    if preProcess then
        preProcess(system, dt)
    end

    if process then
        if system.nocache then
            local entities = system.world.entityList
            local filter = system.filter
            if filter then
                for i = 1, #entities do
                    local entity = entities[i]
                    if filter(system, entity) then
                        process(system, entity, dt)
                    end
                end
            end
        else
            local entities = system.entities
            for i = 1, #entities do
                process(system, entities[i], dt)
            end
        end
    end

    if postProcess then
        postProcess(system, dt)
    end
end

-- Sorts Systems by a function system.sortDelegate(entity1, entity2) on modify.
local function sortedSystemOnModify(system)
    local entities = system.entities
    local indices = system.indices
    local sortDelegate = system.sortDelegate
    if not sortDelegate then
        local compare = system.compare
        sortDelegate = function(e1, e2)
            return compare(system, e1, e2)
        end
        system.sortDelegate = sortDelegate
    end
    tsort(entities, sortDelegate)
    for i = 1, #entities do
        indices[entities[i]] = i
    end
end

--- Creates a new System or System class from the supplied table. If `table` is
-- nil, creates a new table.
function ecs.system(table)
    table = table or {}
    table[systemTableKey] = true
    return table
end

--- Creates a new Processing System or Processing System class. Processing
-- Systems process each entity individual, and are usually what is needed.
-- Processing Systems have three extra callbacks besides those inheritted from
-- vanilla Systems.
--
--     function system:preProcess(dt) -- Called before iteration.
--     function system:process(entity, dt) -- Process each entity.
--     function system:postProcess(dt) -- Called after iteration.
--
-- Processing Systems have their own `update` method, so don't implement a
-- a custom `update` callback for Processing Systems.
-- @see system
function ecs.processingSystem(table)
    table = table or {}
    table[systemTableKey] = true
    table.update = processingSystemUpdate
    return table
end

--- Creates a new Sorted System or Sorted System class. Sorted Systems sort
-- their Entities according to a user-defined method, `system:compare(e1, e2)`,
-- which should return true if `e1` should come before `e2` and false otherwise.
-- Sorted Systems also override the default System's `onModify` callback, so be
-- careful if defining a custom callback. However, for processing the sorted
-- entities, consider `ecs.sortedProcessingSystem(table)`.
-- @see system
function ecs.sortedSystem(table)
    table = table or {}
    table[systemTableKey] = true
    table.onModify = sortedSystemOnModify
    return table
end

--- Creates a new Sorted Processing System or Sorted Processing System class.
-- Sorted Processing Systems have both the aspects of Processing Systems and
-- Sorted Systems.
-- @see system
-- @see processingSystem
-- @see sortedSystem
function ecs.sortedProcessingSystem(table)
    table = table or {}
    table[systemTableKey] = true
    table.update = processingSystemUpdate
    table.onModify = sortedSystemOnModify
    return table
end

--- World functions.
-- A World is a container that manages Entities and Systems. Typically, a
-- program uses one World at a time.
--
-- For all World functions except `ecs.world(...)`, object-oriented syntax can
-- be used instead of the documented syntax. For example,
-- `ecs.add(world, e1, e2, e3)` is the same as `world:add(e1, e2, e3)`.
-- @section World

-- Forward declaration
local worldMetaTable

--- Creates a new World.
-- Can optionally add default Systems and Entities. Returns the new World along
-- with default Entities and Systems.
function ecs.world(...)
    local ret = setmetatable({

        -- List of Entities to remove
        entitiesToRemove = {},

        -- List of Entities to change
        entitiesToChange = {},

        -- List of Entities to add
        systemsToAdd = {},

        -- List of Entities to remove
        systemsToRemove = {},

        -- Set of Entities
        entities = {},

        -- List of Systems
        systems = {}

    }, worldMetaTable)

    ecs_add(ret, ...)
    ecs_manageSystems(ret)
    ecs_manageEntities(ret)

    return ret, ...
end

--- Adds an Entity to the world.
-- Also call this on Entities that have changed Components such that they
-- match different Filters. Returns the Entity.
function ecs.addEntity(world, entity)
    local e2c = world.entitiesToChange
    e2c[#e2c + 1] = entity
    return entity
end
ecs_addEntity = ecs.addEntity

--- Adds a System to the world. Returns the System.
function ecs.addSystem(world, system)
    assert(system.world == nil, "System already belongs to a World.")
    local s2a = world.systemsToAdd
    s2a[#s2a + 1] = system
    system.world = world
    return system
end
ecs_addSystem = ecs.addSystem

--- Shortcut for adding multiple Entities and Systems to the World. Returns all
-- added Entities and Systems.
function ecs.add(world, ...)
    for i = 1, select("#", ...) do
        local obj = select(i, ...)
        if obj then
            if isSystem(obj) then
                ecs_addSystem(world, obj)
            else -- Assume obj is an Entity
                ecs_addEntity(world, obj)
            end
        end
    end
    return ...
end
ecs_add = ecs.add

--- Removes an Entity from the World. Returns the Entity.
function ecs.removeEntity(world, entity)
    local e2r = world.entitiesToRemove
    e2r[#e2r + 1] = entity
    return entity
end
ecs_removeEntity = ecs.removeEntity

--- Removes a System from the world. Returns the System.
function ecs.removeSystem(world, system)
    assert(system.world == world, "System does not belong to this World.")
    local s2r = world.systemsToRemove
    s2r[#s2r + 1] = system
    return system
end
ecs_removeSystem = ecs.removeSystem

--- Shortcut for removing multiple Entities and Systems from the World. Returns
-- all removed Systems and Entities
function ecs.remove(world, ...)
    for i = 1, select("#", ...) do
        local obj = select(i, ...)
        if obj then
            if isSystem(obj) then
                ecs_removeSystem(world, obj)
            else -- Assume obj is an Entity
                ecs_removeEntity(world, obj)
            end
        end
    end
    return ...
end

-- Adds and removes Systems that have been marked from the World.
function ecs_manageSystems(world)
    local s2a, s2r = world.systemsToAdd, world.systemsToRemove

    -- Early exit
    if #s2a == 0 and #s2r == 0 then
        return
    end

    world.systemsToAdd = {}
    world.systemsToRemove = {}

    local worldEntityList = world.entities
    local systems = world.systems

    -- Remove Systems
    for i = 1, #s2r do
        local system = s2r[i]
        local index = system.index
        local onRemove = system.onRemove
        if onRemove and not system.nocache then
            local entityList = system.entities
            for j = 1, #entityList do
                onRemove(system, entityList[j])
            end
        end
        tremove(systems, index)
        for j = index, #systems do
            systems[j].index = j
        end
        local onRemoveFromWorld = system.onRemoveFromWorld
        if onRemoveFromWorld then
            onRemoveFromWorld(system, world)
        end
        s2r[i] = nil

        -- Clean up System
        system.world = nil
        system.entities = nil
        system.indices = nil
        system.index = nil
    end

    -- Add Systems
    for i = 1, #s2a do
        local system = s2a[i]
        if systems[system.index or 0] ~= system then
            if not system.nocache then
                system.entities = {}
                system.indices = {}
            end
            if system.active == nil then
                system.active = true
            end
            system.modified = true
            system.world = world
            local index = #systems + 1
            system.index = index
            systems[index] = system
            local onAddToWorld = system.onAddToWorld
            if onAddToWorld then
                onAddToWorld(system, world)
            end

            -- Try to add Entities
            if not system.nocache then
                local entityList = system.entities
                local entityIndices = system.indices
                local onAdd = system.onAdd
                local filter = system.filter
                if filter then
                    for j = 1, #worldEntityList do
                        local entity = worldEntityList[j]
                        if filter(system, entity) then
                            local entityIndex = #entityList + 1
                            entityList[entityIndex] = entity
                            entityIndices[entity] = entityIndex
                            if onAdd then
                                onAdd(system, entity)
                            end
                        end
                    end
                end
            end
        end
        s2a[i] = nil
    end
end

-- Adds, removes, and changes Entities that have been marked.
function ecs_manageEntities(world)
    local e2r = world.entitiesToRemove
    local e2c = world.entitiesToChange

    -- Early exit
    if #e2r == 0 and #e2c == 0 then
        return
    end

    world.entitiesToChange = {}
    world.entitiesToRemove = {}

    local entities = world.entities
    local systems = world.systems

    -- Change Entities
    for i = 1, #e2c do
        local entity = e2c[i]
        -- Add if needed
        if not entities[entity] then
            local index = #entities + 1
            entities[entity] = index
            entities[index] = entity
        end
        for j = 1, #systems do
            local system = systems[j]
            if not system.nocache then
                local ses = system.entities
                local seis = system.indices
                local index = seis[entity]
                local filter = system.filter
                if filter and filter(system, entity) then
                    if not index then
                        system.modified = true
                        index = #ses + 1
                        ses[index] = entity
                        seis[entity] = index
                        local onAdd = system.onAdd
                        if onAdd then
                            onAdd(system, entity)
                        end
                    end
                elseif index then
                    system.modified = true
                    local tmpEntity = ses[#ses]
                    ses[index] = tmpEntity
                    seis[tmpEntity] = index
                    seis[entity] = nil
                    ses[#ses] = nil
                    local onRemove = system.onRemove
                    if onRemove then
                        onRemove(system, entity)
                    end
                end
            end
        end
        e2c[i] = nil
    end

    -- Remove Entities
    for i = 1, #e2r do
        local entity = e2r[i]
        e2r[i] = nil
        local listIndex = entities[entity]
        if listIndex then
            -- Remove Entity from world state
            local lastEntity = entities[#entities]
            entities[lastEntity] = listIndex
            entities[entity] = nil
            entities[listIndex] = lastEntity
            entities[#entities] = nil
            -- Remove from cached systems
            for j = 1, #systems do
                local system = systems[j]
                if not system.nocache then
                    local ses = system.entities
                    local seis = system.indices
                    local index = seis[entity]
                    if index then
                        system.modified = true
                        local tmpEntity = ses[#ses]
                        ses[index] = tmpEntity
                        seis[tmpEntity] = index
                        seis[entity] = nil
                        ses[#ses] = nil
                        local onRemove = system.onRemove
                        if onRemove then
                            onRemove(system, entity)
                        end
                    end
                end
            end
        end
    end
end

--- Manages Entities and Systems marked for deletion or addition. Call this
-- before modifying Systems and Entities outside of a call to `ecs.update`.
-- Do not call this within a call to `ecs.update`.
function ecs.refresh(world)
    ecs_manageSystems(world)
    ecs_manageEntities(world)
    local systems = world.systems
    for i = #systems, 1, -1 do
        local system = systems[i]
        if system.active then
            local onModify = system.onModify
            if onModify and system.modified then
                onModify(system, 0)
            end
            system.modified = false
        end
    end
end

--- Updates the World by dt (delta time). Takes an optional parameter, `filter`,
-- which is a Filter that selects Systems from the World, and updates only those
-- Systems. If `filter` is not supplied, all Systems are updated. Put this
-- function in your main loop.
function ecs.update(world, dt, filter)
    ecs_manageSystems(world)
    ecs_manageEntities(world)

    local systems = world.systems

    -- Iterate through Systems IN REVERSE ORDER
    for i = #systems, 1, -1 do
        local system = systems[i]
        if system.active then
            -- Call the modify callback on Systems that have been modified.
            local onModify = system.onModify
            if onModify and system.modified then
                onModify(system, dt)
            end
            local preWrap = system.preWrap
            if preWrap and
                ((not filter) or filter(world, system)) then
                preWrap(system, dt)
            end
        end
    end

    --  Iterate through Systems IN ORDER
    for i = 1, #systems do
        local system = systems[i]
        if system.active and ((not filter) or filter(world, system)) then

            -- Update Systems that have an update method (most Systems)
            local update = system.update
            if update then
                local interval = system.interval
                if interval then
                    local bufferedTime = (system.bufferedTime or 0) + dt
                    while bufferedTime >= interval do
                        bufferedTime = bufferedTime - interval
                        update(system, interval)
                    end
                    system.bufferedTime = bufferedTime
                else
                    update(system, dt)
                end
            end

            system.modified = false
        end
    end

    -- Iterate through Systems IN ORDER AGAIN
    for i = 1, #systems do
        local system = systems[i]
        local postWrap = system.postWrap
        if postWrap and system.active and
            ((not filter) or filter(world, system)) then
            postWrap(system, dt)
        end
    end
end

--- Removes all Entities from the World.
function ecs.clearEntities(world)
    local el = world.entities
    for i = 1, #el do
        ecs_removeEntity(world, el[i])
    end
end

--- Removes all Systems from the World.
function ecs.clearSystems(world)
    local systems = world.systems
    for i = #systems, 1, -1 do
        ecs_removeSystem(world, systems[i])
    end
end

--- Gets number of Entities in the World.
function ecs.getEntityCount(world)
    return #world.entities
end

--- Gets number of Systems in World.
function ecs.getSystemCount(world)
    return #world.systems
end

--- Sets the index of a System in the World, and returns the old index. Changes
-- the order in which they Systems processed, because lower indexed Systems are
-- processed first. Returns the old system.index.
function ecs.setSystemIndex(world, system, index)
    local oldIndex = system.index
    local systems = world.systems

    if index < 0 then
        index = ecs.getSystemCount(world) + 1 + index
    end

    tremove(systems, oldIndex)
    tinsert(systems, index, system)

    for i = oldIndex, index, index >= oldIndex and 1 or -1 do
        systems[i].index = i
    end

    return oldIndex
end

-- Construct world metatable.
worldMetaTable = {
    __index = {
        add = ecs.add,
        addEntity = ecs.addEntity,
        addSystem = ecs.addSystem,
        remove = ecs.remove,
        removeEntity = ecs.removeEntity,
        removeSystem = ecs.removeSystem,
        refresh = ecs.refresh,
        update = ecs.update,
        clearEntities = ecs.clearEntities,
        clearSystems = ecs.clearSystems,
        getEntityCount = ecs.getEntityCount,
        getSystemCount = ecs.getSystemCount,
        setSystemIndex = ecs.setSystemIndex
    },
    __tostring = function()
        return "<scarab_ecs_world>"
    end
}

return ecs
