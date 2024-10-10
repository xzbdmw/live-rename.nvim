local lsp_methods = require("vim.lsp.protocol").Methods

local M = {}

local extmark_ns = vim.api.nvim_create_namespace("user.util.input.extmark")
local win_hl_ns = vim.api.nvim_create_namespace("user.util.input.win_hl")
local buf_hl_ns = vim.api.nvim_create_namespace("user.util.input.buf_hl")

local cfg = {
    request_timeout = 1500,
    hl = {
        current = "CurSearch",
        others = "Search",
    },
}

--- session context
local C = {}

function M.setup(user_cfg)
    cfg = vim.tbl_deep_extend("force", cfg, user_cfg or {})
end

function M.map(opts)
    return function()
        M.rename(opts)
    end
end

--- slightly modified from `vim.lsp.client.lua`
---@param client vim.lsp.Client
---@param method string
---@param params lsp.TextDocumentPositionParams
---@param bufnr integer
---@return table<string,any>?
local function lsp_request_sync(client, method, params, bufnr)
    local request_result = nil
    local function sync_handler(err, result, context, config)
        request_result = {
            err = err,
            result = result,
            context = context,
            config = config,
        }
    end

    local success, request_id = client.request(method, params, sync_handler, bufnr)
    if not success then
        return nil
    end

    local wait_result = vim.wait(cfg.request_timeout, function()
        return request_result ~= nil
    end, 5)

    if not wait_result then
        if request_id then
            client.cancel_request(request_id)
        end
        return nil
    end
    return request_result
end

local function references_handler(transaction_id)
    ---@param err string?
    ---@param result lsp.Location[]?
    return function(err, result)
        -- check if the user is still in the same renaming session
        if C.ref_transaction_id == nil or C.ref_transaction_id ~= transaction_id then
            return
        end

        if err or result == nil then
            vim.notify(string.format("[LSP] rename, error getting references: `%s`", err))
            return
        end

        ---@type lsp.Range[]
        local editing_ranges = {}
        ---@type lsp.Position
        local pos = C.pos_params.position

        local on_same_line = 0
        for _, loc in ipairs(result) do
            if vim.uri_to_bufnr(loc.uri) == C.doc_buf then
                local range = loc.range
                if range.start.line ~= range["end"].line then
                    goto continue
                end
                if range.start.line ~= pos.line then
                    -- on other line
                    table.insert(editing_ranges, loc.range)
                elseif pos.character < range.start.character or pos.character >= range["end"].character then
                    -- on same line but not inside the character range
                    if pos.character >= range["end"].character then
                        on_same_line = on_same_line + 1
                    end
                    table.insert(editing_ranges, loc.range)
                end
            end
            ::continue::
        end

        -- update window position
        if on_same_line > 0 then
            local win_opts = {
                -- relative to buffer text
                relative = "win",
                win = C.doc_win,
                bufpos = { C.line, C.col },
                row = 0,
                -- correct for extmarks on the same line
                col = -on_same_line * #C.cword,
            }
            vim.api.nvim_win_set_config(C.win, win_opts)
        end

        -- also show edit in other occurrences
        C.editing_ranges = {}
        for _, range in ipairs(editing_ranges) do
            local line = range.start.line
            local start_col =
                vim.lsp.util._get_line_byte_from_position(C.doc_buf, range.start, C.client.offset_encoding)
            local end_col = vim.lsp.util._get_line_byte_from_position(C.doc_buf, range["end"], C.client.offset_encoding)

            local extmark_id = vim.api.nvim_buf_set_extmark(C.doc_buf, extmark_ns, line, start_col, {
                end_col = end_col,
                virt_text_pos = "inline",
                virt_text = { { C.new_text, cfg.hl.others } },
                conceal = "",
            })

            table.insert(C.editing_ranges, {
                extmark_id = extmark_id,
                line = line,
                start_col = start_col,
                end_col = end_col,
            })
        end
    end
end

function M.rename(opts)
    opts = opts or {}

    local cword = vim.fn.expand("<cword>")
    local text = opts.text or cword or ""
    local text_width = vim.fn.strdisplaywidth(text)

    C.cword = cword
    C.new_text = text
    C.doc_buf = vim.api.nvim_get_current_buf()
    C.doc_win = vim.api.nvim_get_current_win()

    -- get word start
    local old_pos = vim.api.nvim_win_get_cursor(C.doc_win)
    C.line = old_pos[1] - 1
    vim.fn.search(cword, "bc")
    local new_pos = vim.api.nvim_win_get_cursor(C.doc_win)
    vim.api.nvim_win_set_cursor(0, old_pos)
    C.col = old_pos[2]
    C.end_col = C.col
    if new_pos[1] == old_pos[1] then
        C.col = new_pos[2]
        C.end_col = C.col + #cword
    end

    local clients = vim.lsp.get_clients({
        bufnr = C.doc_buf,
        method = lsp_methods.rename,
    })
    if #clients == 0 then
        vim.notify("[LSP] rename, no matching server attached")
        return
    end

    -- try to find a client that suuports `textDocuent/references`
    for _, client in ipairs(clients) do
        if client.supports_method(lsp_methods.textDocument_references) then
            C.pos_params = vim.lsp.util.make_position_params(C.doc_win, client.offset_encoding)
            C.pos_params.context = { includeDeclaration = true }
            C.client = client
            break
        end
    end
    if C.client then
        local transaction_id = math.random()
        local handler = references_handler(transaction_id)
        C.client.request(lsp_methods.textDocument_references, C.pos_params, handler, C.doc_buf)
        C.ref_transaction_id = transaction_id
    else
        -- default to the first client that supports renaming
        local client = clients[1]
        C.pos_params = vim.lsp.util.make_position_params(C.doc_win, client.offset_encoding)
        C.pos_params.context = { includeDeclaration = true }
        C.client = client
    end

    -- conceal word in document with spaces, requires at least concealleval=2
    C.prev_conceallevel = vim.wo[C.doc_win].conceallevel
    vim.wo[C.doc_win].conceallevel = 2

    C.extmark_id = vim.api.nvim_buf_set_extmark(C.doc_buf, extmark_ns, C.line, C.col, {
        end_col = C.end_col,
        virt_text_pos = "inline",
        virt_text = { { string.rep(" ", text_width), cfg.hl.current } },
        conceal = "",
    })

    -- create buf
    C.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(C.buf, "lsp:rename")
    vim.api.nvim_buf_set_lines(C.buf, 0, 1, false, { text })

    -- create win
    local win_opts = {
        -- relative to buffer text
        relative = "win",
        win = C.doc_win,
        bufpos = { C.line, C.col },
        row = 0,
        col = 0,

        width = text_width + 2,
        height = 1,
        style = "minimal",
        border = "none",
    }
    C.cursor = vim.api.nvim_win_get_cursor(0)
    C.parent_win = vim.api.nvim_get_current_win()
    C.win = vim.api.nvim_open_win(C.buf, false, win_opts)
    vim.b[C.buf].rename = true
    vim.wo[C.win].wrap = true

    -- highlights and transparency
    vim.api.nvim_set_option_value("winblend", 100, {
        scope = "local",
        win = C.win,
    })
    vim.api.nvim_set_hl(win_hl_ns, "Normal", { fg = nil, bg = nil })
    vim.api.nvim_win_set_hl_ns(C.win, win_hl_ns)

    -- key mappings
    vim.api.nvim_buf_set_keymap(C.buf, "n", "<cr>", "", { callback = M.submit, noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(C.buf, "v", "<cr>", "", { callback = M.submit, noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(C.buf, "i", "<cr>", "", { callback = M.submit, noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(C.buf, "n", "<esc>", "", { callback = M.hide, noremap = true, silent = true })
    vim.api.nvim_buf_set_keymap(C.buf, "n", "q", "", { callback = M.hide, noremap = true, silent = true })

    local group = vim.api.nvim_create_augroup("live-rename", {})
    -- update when input changes
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP", "CursorMoved" }, {
        group = group,
        buffer = C.buf,
        callback = M.update,
    })
    -- cleanup when window is closed
    vim.api.nvim_create_autocmd("WinClosed", {
        group = group,
        buffer = C.buf,
        callback = M.hide,
        once = true,
    })

    -- focus and enter insert mode
    vim.api.nvim_set_current_win(C.win)
    if opts.insert then
        vim.cmd.startinsert()
        vim.api.nvim_win_set_cursor(C.win, { 1, text_width })
    end
end

function M.update()
    C.new_text = vim.api.nvim_buf_get_lines(C.buf, 0, 1, false)[1]
    local text_width = vim.fn.strdisplaywidth(C.new_text)

    vim.api.nvim_buf_set_extmark(C.doc_buf, extmark_ns, C.line, C.col, {
        id = C.extmark_id,
        end_col = C.end_col,
        virt_text_pos = "inline",
        virt_text = { { string.rep(" ", text_width), cfg.hl.current } },
        conceal = "",
    })

    -- also show edit in other occurrences
    if C.editing_ranges then
        for _, e in ipairs(C.editing_ranges) do
            vim.api.nvim_buf_set_extmark(C.doc_buf, extmark_ns, e.line, e.start_col, {
                id = e.extmark_id,
                end_col = e.end_col,
                virt_text_pos = "inline",
                virt_text = { { C.new_text, cfg.hl.others } },
                conceal = "",
            })
        end
    end

    vim.api.nvim_buf_clear_namespace(C.buf, buf_hl_ns, 0, -1)
    vim.api.nvim_buf_add_highlight(C.buf, buf_hl_ns, cfg.hl.current, 0, 0, -1)

    -- avoid line wrapping due to the window being to small
    vim.api.nvim_win_set_width(C.win, text_width + 2)
end

local function show_success_message(result)
    local changed_instances = 0
    local changed_files = 0

    local with_edits = result.documentChanges ~= nil
    for _, change in pairs(result.documentChanges or result.changes) do
        changed_instances = changed_instances + (with_edits and #change.edits or #change)
        changed_files = changed_files + 1
    end

    local message = string.format(
        "Renamed **%s** instance%s",
        changed_instances,
        changed_instances == 1 and "" or "s",
        changed_files,
        changed_files == 1 and "" or "s"
    )
    vim.notify(message)
end

local post_hook = function(result)
    if not result then
        print(string.format("could not perform rename"))
        return
    end
    local notifications = {}
    local entries = {}
    local num_files, num_updates = 0, 0

    -- 收集信息以用于对齐
    local max_uri_length = 0
    local max_edit_count_length = 0
    local changes = {}

    -- 遍历 result.changes
    if result.changes then
        for uri, edits in pairs(result.changes) do
            num_files = num_files + 1
            local bufnr = vim.uri_to_bufnr(uri)
            local short_uri = string.sub(vim.uri_to_fname(uri), #vim.fn.getcwd() + 2)
            max_uri_length = math.max(max_uri_length, #short_uri)
            max_edit_count_length = math.max(max_edit_count_length, #tostring(#edits))

            for _, edit in ipairs(edits) do
                local start_line = edit.range.start.line + 1
                local line = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, start_line, false)[1]
                num_updates = num_updates + 1
                table.insert(entries, {
                    bufnr = bufnr,
                    lnum = start_line,
                    col = edit.range.start.character + 1,
                    text = line,
                })
            end
            table.insert(changes, { short_uri = short_uri, edit_count = #edits })
        end
    end

    -- 遍历 result.documentChanges
    if result.documentChanges then
        for _, c in pairs(result.documentChanges) do
            local edits = c.edits
            local textDocument = c.textDocument
            local uri = textDocument.uri
            num_files = num_files + 1
            local bufnr = vim.uri_to_bufnr(uri)
            local short_uri = string.sub(vim.uri_to_fname(uri), #vim.fn.getcwd() + 2)
            max_uri_length = math.max(max_uri_length, #short_uri)
            max_edit_count_length = math.max(max_edit_count_length, #tostring(#edits))

            for _, edit in ipairs(edits) do
                local start_line = edit.range.start.line + 1
                local line = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, start_line, false)[1]
                num_updates = num_updates + 1
                table.insert(entries, {
                    bufnr = bufnr,
                    lnum = start_line,
                    col = edit.range.start.character + 1,
                    text = line,
                })
            end
            table.insert(changes, { short_uri = short_uri, edit_count = #edits })
        end
    end

    -- 格式化通知信息
    for i, change in ipairs(changes) do
        local notification = string.format("- %-" .. max_uri_length .. "s: **%d**", change.short_uri, change.edit_count)
        table.insert(notifications, notification)
    end
    table.insert(notifications, 1, " ")
    vim.fn.setqflist(entries, "r")
    if num_files > 1 then
        vim.notify(table.concat(notifications, "\n"), vim.log.levels.INFO)
        FeedKeys("<c-q>", "m")
    else
        show_success_message(result)
    end
end

function M.submit()
    local new_text = vim.api.nvim_buf_get_lines(C.buf, 0, 1, false)[1]
    local mode = vim.api.nvim_get_mode().mode
    if mode == "i" then
        vim.cmd.stopinsert()
    end

    -- do a sync request to avoid flicker when deleting extmarks
    local params = {
        textDocument = C.pos_params.textDocument,
        position = C.pos_params.position,
        newName = new_text,
    }
    local resp = lsp_request_sync(C.client, lsp_methods.textDocument_rename, params, C.doc_buf)
    if resp then
        local handler = C.client.handlers[lsp_methods.textDocument_rename]
            or vim.lsp.handlers[lsp_methods.textDocument_rename]
        handler(resp.err, resp.result, resp.context, resp.config)
        post_hook(resp.result)
    end

    M.hide()
end

function M.hide()
    vim.wo[C.doc_win].conceallevel = C.prev_conceallevel
    vim.api.nvim_buf_clear_namespace(C.doc_buf, extmark_ns, 0, -1)

    if C.win and vim.api.nvim_win_is_valid(C.win) then
        vim.api.nvim_win_close(C.win, false)
    end

    if C.buf and vim.api.nvim_buf_is_valid(C.buf) then
        vim.api.nvim_buf_delete(C.buf, {})
    end
    if C.cursor == nil then
        return
    end
    vim.api.nvim_win_set_cursor(C.parent_win, { C.cursor[1], C.cursor[2] + 1 })
    vim.g.neovide_floating_z_height = 5
    vim.g.neovide_cursor_animation_length = 0

    -- reset context
    C = {}
end

return M
