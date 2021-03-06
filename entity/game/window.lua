require "util.class"

function uiNode()
    local root = am.translate(0,0):tag("UI-ROOT")

    local cl = am.translate(0,0):tag("UI-CURSOR") 
  
    local pl = am.translate(0,0):tag("UI-POPUP")

    local ug = am.translate(0,0):tag("UI-GENERAL") 

    local ui = root
               ^cl
               ^pl
               ^ug
               
    function ui:attach_cursor(n)
        cl:append(n)
    end

    function ui:detach_cursor(n)
        cl:remove(n)
    end

    function ui:attach_popup(n)
        pl:append(n)
    end

    function ui:detach_popup(n)
        pl:remove(n)
    end

    function ui:attach(n)
        ug:append(n)
    end

    function ui:detach(n)
        ug:remove(n)
    end

    return ui
end

function sceneNode()
    local root = am.translate(0,0):tag("SCENE-ROOT")

    local sg = am.translate(0,0):tag("SCENE-GENERAL")

    local s = root
               ^sg

    function sg:attach(n)
        sg:append(n)
    end

    function sg:detach(n)
        sg:remove(n)
    end

    return s 
end

function rootNode()
    local r = am.translate(0,0):tag("ROOT")

    local uiLayer = uiNode()

    local sceneLayer = sceneNode()

    local root = r
                 ^uiLayer
                 ^sceneLayer

    function root:SetCursor(n)
        n.hidden = false
        uiLayer:attach_cursor(n)
    end

    function root:RemoveCursor(n)
        n.hidden = true
        uiLayer:detach_cursor(n)
    end 

    function root:SetUi(n)
        n.hidden = false
        uiLayer:attach(n)
    end

    function root:RemoveUi(n)
        n.hidden = true
        uiLayer:detach(n)
    end

    function root:SetScene(n)
        n.hidden = false
        sceneLayer:atach(n)
    end

    function root:RemoveScene(n)
        sceneLayer:detach(n)
    end

    return root 
end

local function attachRoot(window)
    local root = rootNode() 
    window.scene = root
end

local function attachWorld(window, world)
    local scene = window.scene

    scene:action(
        coroutine.create(
            function()
                while true do
                    world.update(world, am.current_time())
                    coroutine.yield()
                end
            end)
    )
end

class("GameWindow")

function GameWindow:GameWindow(game)
    local current = game.window
    -- local broker  = game.broker
    local world = game.world
    self.game = true
    self.window = true
    attachRoot(current)
    attachWorld(current, world)
    self.game_window = current
end

function GameWindow:Current()
    return self.game_window
end
