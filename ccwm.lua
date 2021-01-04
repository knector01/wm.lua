local processes = {}
local process_focus = 0
local process_current = 0

-- Events which should be sent to the focused window
local EVENTS_KEYBD = {"char","key","key_up","paste","terminate"}
-- Events which have XY coordinates and should be sent to the window they are over
local EVENTS_MOUSE = {"mouse_click","mouse_up","mouse_scroll","mouse_drag"}
-- Other events (rednet, timers, etc) are sent to all windows

-- Minimum window size
local MIN_WIDTH = 4
local MIN_HEIGHT = 3

local SHADOW_ENABLE = false

local term_original = term.current()

local default_width = 20
local default_height = 10

local drag_state

DRAG_MOVE = 0
DRAG_RESIZE = 1

local draw_background = false

local multishell_ext = {}

local function str_pad(str, length)
	if #str > length then
		str = string.sub(str,1,length)
	elseif #str < length then
		str = str .. string.rep(" ",length-#str)
	end
	return str
end

local function contains(arr, elem)
	for _, v in pairs(arr) do
		if v == elem then
			return true
		end
	end
	return false
end

local function table_copy(tbl)
	local copy = {}
	for k,v in pairs(tbl) do
		copy[k] = v
	end
	return copy
end

local function process_subwindow_properties(id)
	local process = processes[id]
	if process.border then
		return process.x, process.y+1, process.w, process.h-1
	end
	return process.x, process.y, process.w, process.h
end

-- schedules a redraw
-- (no arguments): redraw everything
-- (id): redraw border of specified window, as well as border
--       and contents of all windows above it
-- (id, force): same as id, except if force is true then also
--       redraw contents of the specified window
local function wm_dirty(id,force)
	if id then
		local process = processes[id]
		if force then
			process.dirty = 2
		elseif process.dirty == 0 then
			process.dirty = 1
		end
		for i=id+1,#processes do
			processes[i].dirty = 2
		end
	else
		draw_background = true
		for i=1,#processes do
			processes[i].dirty = 2
		end
	end
end

local function process_end(id)
	table.remove(processes, id)
	if process_focus > #processes then
		process_focus = #processes
	end
	wm_dirty()
end

local function process_resume(id, args)
	local process = processes[id]
	if process.filter and args[1] ~= process.filter and args[1] ~= "terminate" then return end
	process_current = id
	term.redirect(process.window)
	local status
	status, process.filter = coroutine.resume(process.coroutine, unpack(args))
	if coroutine.status(process.coroutine) == "dead" then --not status then --
		process_end(id)
	else
		wm_dirty(id)
	end
	process_current = 0
	term.redirect(term_original)
end

-- base process constructor
-- runs an arbitrary function inside a process
local function process_create(func, title, x, y, w, h)
	local process = {}
	
	local current_run = process_current
	
	table.insert(processes, process)
	
	process.coroutine = coroutine.create(func)
	
	process.x = x or 4
	process.y = y or 4
	process.w = w or default_width
	process.h = h or default_height
	process.visible = true
	process.border = true
	process.title = title
	process.dirty = 2
	process.filter = nil
	process.maximized = false
	process.old_pos = {}
	
	px,py,pw,ph = process_subwindow_properties(#processes)
	process.window = window.create(term_original,px,py,pw,ph,true)
	
	process_resume(#processes,{})
	
	if current_run > 0 then
		process_current = current_run
		processes[current_run].window.restoreCursor()
		term.redirect(processes[current_run].window)
	end
	
	return #processes
end

-- wraps an os.run call inside a process
local function process_run(env, path, args, title, x, y, w, h)
	run_args = {}
	table.insert(run_args, env)
	table.insert(run_args, path)
	for i=1,#args do
		table.insert(run_args,args[i])
	end
	title = title or path
	return process_create(function() os.run(unpack(run_args)) end, title, x, y, w, h)
end

-- runs a shell command inside a process,
-- and lets the CraftOS shell set up the environment
-- is this hacky? maybe
-- it does seem to work though
local function process_run_command(command, x, y, w, h)
	-- not sure if i'm doing this right, honestly
	-- seems to work though
	
	--if not env then
	env = {shell=shell, multishell=multishell_ext} --table_copy(_G)
	--end
	
	process_run(env, shell.resolveProgram("shell"), {command}, command, x, y, w, h)
end

local function process_reposition(id, x, y, w, h)
	local process = processes[id]
	local resized = false
	
	w = w or process.w
	h = h or process.h
	
	if w ~= process.w or h ~= process.h then
		resized = true
	end
	
	process.x = x
	process.y = y
	
	process.w = w
	process.h = h
	
	px,py,pw,ph = process_subwindow_properties(#processes)
	process.window.reposition(px,py,pw,ph)
	
	if resized then
		process_resume(id, {"term_resize"})
	end
	--wm_draw()
	wm_dirty()
end

local function process_set_visible(id, visible)
	local process = processes[id]
	process.visible = visible
	process.window.setVisible(visible)
	wm_dirty()
end

local function process_set_title(id, title)
	local process = processes[id]
	process.title = title
	wm_dirty(id)
end

local function process_set_maximized(id, maximized)
	local process = processes[id]
	process.maximized = maximized
	if maximized then
		process.old_pos.x = process.x
		process.old_pos.y = process.y
		process.old_pos.w = process.w
		process.old_pos.h = process.h
		w,h = term.getSize()
		process_reposition(id,1,1,w,h)
	else
		process_reposition(id,
			process.old_pos.x,process.old_pos.y,
			process.old_pos.w,process.old_pos.h)
	end
end

local function process_set_focus(id, top)
	if process_focus > 0 then
		wm_dirty(process_focus)
	end
	if top then
		-- move the window to the top
		-- TODO: decouple process ID from window layering
		local process = processes[id]
		table.remove(processes,id)
		table.insert(processes,process)
		process_focus = #processes
		wm_dirty(process_focus,true)
	else
		process_focus = id
		wm_dirty(process_focus)
	end
end

-- draw a window's header and its contents,
-- depending on what dirty flags are set
local function process_draw(id)
	-- TODO: Add other border styles
	-- Current implementation can cover information (e.g. CC edit line number)
	local process = processes[id]
	if process.visible and process.dirty > 0 then
		if process.dirty == 2 then
			process.window.redraw()
		end
		if SHADOW_ENABLE then
			term.setBackgroundColor(colors.gray)
			for i=1,process.w do
				term.setCursorPos(process.x+i,process.y+process.h)
				term.write(" ")
			end
			for i=1,process.h-1 do
				term.setCursorPos(process.x+process.w,process.y+i)
				term.write(" ")
			end
		end
		if process.border then
			local title_color = colors.gray
			if id == process_focus then
				title_color = colors.blue
			end
			
			term.setBackgroundColor(title_color)
			term.setTextColor(colors.white)
			term.setCursorPos(process.x, process.y)
			term.write(str_pad(process.title,process.w-3))
			
			term.setBackgroundColor(colors.white)
			term.setTextColor(title_color)
			term.write(string.char(22,23))
			
			term.setBackgroundColor(colors.red)
			term.setTextColor(colors.white)
			term.write("x")
			
			if not process.maximized then
				term.setCursorPos(process.x+process.w-1,process.y+process.h-1)
				term.setBackgroundColor(colors.white)
				term.setTextColor(colors.lightGray)
				term.write(string.char(127))
			end
		end
		process.dirty = 0
	end
end

-- return true to block click event from the process
local function wm_handle_window_click(id, event)
	local process = processes[id]
	if not process.border then return false end
	if event[4] == process.y then
		if event[2] == 1 then
			if event[3] == process.x + process.w - 1 then
				-- close
				process_end(id)
			elseif event[3] == process.x + process.w - 2 then
				-- maximize
				process_set_maximized(id, not process.maximized)
			elseif event[3] == process.x + process.w - 3 then
				-- minimize
				-- TODO: add a way to restore minimized windows
				-- currently they are lost to the void
				process_set_visible(id, false)
			elseif not process.maximized then
				drag_state = {}
				drag_state.id = id
				drag_state.mode = DRAG_MOVE
				drag_state.offset = event[3] - process.x
			end
		end
		return true
	elseif event[4] == process.y+process.h-1 and not process.maximized then
		if event[3] == process.x+process.w-1 then
			drag_state = {}
			drag_state.id = id
			drag_state.mode = DRAG_RESIZE
			return true
		end
	end
	return false
end

local function wm_handle_mouse_event(event)
	-- TODO: Handle positional events properly
	-- Send to window below event, change focus if other window clicked
	-- If title bar of window clicked, close, minimize, maximize, or start drag
	-- If lower-right corner clicked, resize
	
	-- BUG: Switching focus sends initial click event to wrong window
	
	if drag_state then
		if event[1] == "mouse_up" then
			drag_state = nil
		elseif event[1] == "mouse_drag" then
			if drag_state.mode == DRAG_MOVE then
				local process = processes[drag_state.id]
				process_reposition(
					drag_state.id,
					event[3]-drag_state.offset,
					event[4]
				)
			elseif drag_state.mode == DRAG_RESIZE then
				local process = processes[drag_state.id]
				process_reposition(
					drag_state.id,
					process.x,
					process.y,
					math.max(event[3]-process.x+1,MIN_WIDTH),
					math.max(event[4]-process.y+1,MIN_HEIGHT)
				)
			end
		end
		return
	end
	
	local hit_window = false
	if #processes > 0 then
		for i=#processes,1,-1 do
			local process = processes[i]
			--term.setTextColor(colors.black)
			--print(process.x)
			-- event within window borders?
			
			if (process.visible and
				event[3] >= process.x and 
				event[4] >= process.y and 
				event[3] < process.x+process.w and
				event[4] < process.y+process.h) then
				
				hit_window = true
				x,y,w,h = process_subwindow_properties(i)
				
				local new_id = i
				local skip = false
				
				if event[1] == "mouse_click" then
					process_set_focus(i,true)
					local new_id = #processes
					skip = wm_handle_window_click(new_id, event)
				end
				
				-- event within window contents?
				if ((not skip) and
					event[3] >= x and 
					event[4] >= y and 
					event[3] < x+w and
					event[4] < y+h) then
					
					event[3] = event[3] - x + 1
					event[4] = event[4] - y + 1
					process_resume(new_id,event)
				end
				
				break
			end
		end
	end
	if (not hit_window) and event[1] == "mouse_click" then
		process_run_command(nil,event[3],event[4])
		--wm_draw()
	end
end

local function wm_handle_event(event)
	local is_mouse = contains(EVENTS_MOUSE,event[1])
	local is_keybd = contains(EVENTS_KEYBD,event[1])
	
	-- this is only needed if running a copy of the WM inside itself
	-- doing such a thing is so unbelievably silly that i had no choice but to support it
	if event[1] == "term_resize" then
		w,h = term.getSize()
		for i=1,#processes do
			if processes[i].maximized then
				process_reposition(i,1,1,w,h)
			end
		end
		wm_dirty()
	end
	
	if is_mouse then
		wm_handle_mouse_event(event)
	elseif is_keybd then
		if process_focus > 0 then
			process_resume(process_focus,event)
		end
	else
		for i=1,#processes do
			process_resume(i,event)
		end
	end
end

-- draw the background and all windows
local function wm_draw()
	-- TODO: optimize, only repaint when necessary
	--   e.g. repaint stacked windows over running window,
	--   only full repaint on move/resize/close
	
	if draw_background then
		term.setBackgroundColor(colors.lightBlue)
		term.clear()
		draw_background = false
	end
		
	for i=1,#processes do
		process_draw(i)
	end
	if process_focus > 0 then
		processes[process_focus].window.restoreCursor()
	else
		term.setCursorBlink(false)
	end
	term.setBackgroundColor(colors.black)
	term.setTextColor(colors.white)
end

local function wm_mainloop()
	--process_create()
	wm_dirty()
	while true do
		wm_draw()
		evt = {os.pullEventRaw()}
		if evt[1] == "terminate" and process_focus == 0 then
			break
		end
		wm_handle_event(evt)
	end
end

-- Multishell extensions to provide proper windowing functionality to programs
multishell_ext.getFocus = function() return process_focus end
multishell_ext.setFocus = function(n) process_set_focus(n) end
multishell_ext.getTitle = function(n) return processes[n].getTitle() end
multishell_ext.setTitle = function(n, title) process_set_title(n, title) end
multishell_ext.getCurrent = function() return process_current end
multishell_ext.getCount = function() return #processes end
multishell_ext.launch = function(tProgramEnv, sProgramPath, ...)
	return process_run(tProgramEnv, sProgramPath, {...})
end


process_run_command(nil)
process_set_focus(1)
--processes[1].border = false
--process_reposition(1,5,5)
wm_mainloop()

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1,1)