local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values
local actions = require('telescope.actions')
local actions_state = require('telescope.actions.state')

-- All with `_` as local is also a keyword
local hl_groups = {
    _bad = "TelescopeSpellErrorBad",
    _rare = "TelescopeSpellErrorRare",
    _local = "TelescopeSpellErrorLocal",
    _caps = "TelescopeSpellErrorCap",
}

--- Get the cursor position in the buffer
---@return integer[] { row, col } The current cursor position (row: 1-based, col: 0-based)
local function get_cursor_pos()
    return vim.api.nvim_win_get_cursor(0)
end

--- Set the cursor position in the buffer
---@param pos integer[] {row, col} (row 1-based, col 0-based)
local function set_cursor_position(pos)
    return vim.api.nvim_win_set_cursor(0, pos)
end

--- Jump to the first spell error
--- @return nil
local function go_to_first_spell_error()
    -- Needs to be a synchronous call, so not `vim.api.nvim_feedkeys` or
    --  `vim.api.nvim_input` not possible,
    --  otherwise it ends up in the telescope prompt
    vim.api.nvim_command("silent normal! gg0]s")
end

--- Jump to the next spell error
--- @return nil
local function go_to_next_spell_error()
    vim.api.nvim_command("silent normal! ]s")
end

--- Get all spell errors in the current buffer
---@return table[] spellerrors
local function get_spell_errors()
    local filename = vim.api.nvim_buf_get_name(0)
    local original_pos = get_cursor_pos()

    go_to_first_spell_error()

    local spellerrors = {}

    local first_pos = get_cursor_pos()
    local word, error_type

    -- `]s` can fail to advance or fail to wrap (e.g. Treesitter `@nospell`
    --  regions in markdown), so bound the walk by the buffer size instead of
    --  relying solely on returning to `first_pos`
    local max_iterations = vim.api.nvim_buf_line_count(0) * 10
    local pos = first_pos
    local seen = {}
    for _ = 1, max_iterations do
        local key = pos[1] .. ":" .. pos[2]
        if seen[key] then
            break
        end
        seen[key] = true

        word, error_type = unpack(vim.fn.spellbadword())
        if word == "" then
            break
        end

        table.insert(spellerrors, {
            filename = filename,
            word = word,
            error_type = error_type,
            line_num = pos[1],
            col_num = pos[2] + 1,
        })

        go_to_next_spell_error()
        pos = get_cursor_pos()
    end

    set_cursor_position(original_pos)

    return spellerrors
end

-- Declared separately so the body can call itself to reopen the picker
local telescope_spell_errors
--- Open a Telescope picker with all spell errors in the current buffer
--- @param opts table Telescope options
--- @return nil
telescope_spell_errors = function(opts)
    if not vim.api.nvim_get_option_value("spell", {}) then
        vim.notify("Spell checking is not enabled in the current buffer. See `:h spell`", vim.log.levels.WARN)
        return
    end

    local main_win = vim.api.nvim_get_current_win()
    local main_bufnr = vim.api.nvim_win_get_buf(main_win)

    opts = opts or {}

    --- Create an entry maker for the spell errors
    --- @return function(entry) Entry maker function for Telescope
        --- @param entry table Spell error entry with fields: filename, word, error_type, line_num, col_num
        --- @return table Telescope entry with fields: value, display, ordinal, filename, type
    local function make_entry_maker()
        return function(entry)
            local pos = string.format("%4d:%3d", entry.line_num, entry.col_num)
            local type_and_pos = string.format("%-5s", string.upper(entry.error_type)) .. pos
            local highlight_len = string.len(type_and_pos)
            local highlight_group = hl_groups["_" .. entry.error_type]
            local sep = "  ▏ "
            local dispaly_str = type_and_pos .. sep .. entry.word
            return {
                value = entry,
                display = function(_)
                    return dispaly_str, { { { 0, highlight_len }, highlight_group } }
                end,
                ordinal = dispaly_str,
                filename = entry.filename,
                type = entry.error_type,
                lnum = entry.line_num,
                col = entry.col_num,
            }
        end
    end

    local picker = pickers.new(opts, {
        prompt_title = "Spell Errors",
        finder = finders.new_table {
            results = get_spell_errors(),
            entry_maker = make_entry_maker(),
        },
        previewer = conf.qflist_previewer(opts),
        sorter = conf.prefilter_sorter {
            tag = "type",
            sorter = conf.generic_sorter(opts),
        },
        attach_mappings = function(prompt_bufnr, map)

            --- Fix the selected entry w/ first suggestion
            --- @param op string Operation: "correct", "good", "wrong"
            --- @return nil
            local function auto_correct(op)
                return function()
                    local selection = actions_state.get_selected_entry()
                    local picker = actions_state.get_current_picker(prompt_bufnr)
                    local new_results

                    -- Operations need to be applied to main window, not prompt/picker
                    vim.api.nvim_win_call(main_win, function()
                        local cmd
                        if op == "correct" then
                            -- Auto-correct the word with the first suggestion
                            cmd = "normal! 1z="
                        elseif op == "good" then
                            -- Mark word as good
                            cmd = "normal! zg"
                        else
                            -- Mark word as wrong
                            cmd = "normal! zw"
                        end
                        vim.cmd("normal! m'")
                        vim.api.nvim_win_set_cursor(0, {selection.value.line_num, selection.value.col_num})
                        vim.cmd(cmd)
                        new_results = get_spell_errors()
                    end)
                    picker:refresh(finders.new_table {
                        results = new_results,
                        entry_maker = make_entry_maker(),
                    }, { reset_prompt = true })
                end
            end

            --- Fix all spell errors of the specified type in the buffer
            --- @param type string Spell error type: "bad", "rare", "local", "caps", "buffer" (all types)
            --- @return nil
            local function fix_all_errors(type)
                return function()
                    local selection = actions_state.get_selected_entry()
                    local picker = actions_state.get_current_picker(prompt_bufnr)
                    local type = type or selection.value.error_type
                    local new_results

                    -- Operations need to be applied to main window, not prompt/picker
                    vim.api.nvim_win_call(main_win, function()
                        local results = get_spell_errors()

                        local filtered_results
                        if type == "buffer" then
                            -- No filtering, apply to all errors in buffer
                            filtered_results = results
                        else
                            -- Filter the results to only include the specified type
                            filtered_results = vim.tbl_filter(function(error)
                                return error.error_type == type
                            end, results)
                        end

                        local count = #filtered_results
                        -- Apply the operation to each error of the specified type
                        for _, error in ipairs(filtered_results) do
                            vim.api.nvim_win_set_cursor(0, {error.line_num, error.col_num})
                            vim.cmd("normal! 1z=")
                        end
                        -- Confirmation
                        vim.notify("Fixed all " .. tostring(count) .. " '" .. type:gsub("^%l", string.upper) .. "' errors", vim.log.levels.INFO)

                        -- Refresh the picker with the updated spell errors
                        new_results = get_spell_errors()
                    end)
                    picker:refresh(finders.new_table {
                        results = new_results,
                        entry_maker = make_entry_maker(),
                    }, { reset_prompt = true })
                end
            end

            --- Open a nested picker with suggestions for the selected entry
            --- @return nil
            local function open_suggestions()
                local selection = actions_state.get_selected_entry()
                local word = selection.value.word
                local line_num = selection.value.line_num
                local col_num = selection.value.col_num

                -- Get suggestions list programmatically (rather than `normal! z=`)
                local suggestions = vim.fn.spellsuggest(word)
                if vim.tbl_isempty(suggestions) then
                    vim.notify("No suggestions for '" .. word .. "'", vim.log.levels.INFO)
                    return
                end

                -- Nested picker that re-opens (not refreshes) the spell error picker after selection
                pickers.new(opts, {
                    prompt_title = "Suggestions: " .. word,
                    finder = finders.new_table { results = suggestions },
                    sorter = conf.generic_sorter(opts),
                    attach_mappings = function(suggestion_bufnr)
                        actions.select_default:replace(function()
                            local choice = actions_state.get_selected_entry()[1]
                            actions.close(suggestion_bufnr)

                            local row = line_num - 1
                            local start_col = col_num - 1
                            vim.api.nvim_buf_set_text(
                                main_bufnr, row, start_col, row, start_col + #word, { choice }
                            )

                            -- Reopen the spell error picker after the suggestion is applied
                            vim.schedule(function()
                                vim.api.nvim_set_current_win(main_win)
                                -- Reopening (not refreshing) re-reads the spell errors,
                                -- so the list comes back with the correction applied
                                telescope_spell_errors(opts)
                            end)
                        end)
                        return true
                    end,
                }):find()
            end

            -- Keybindings
            map('i', '<C-c>', auto_correct("correct"))
            map('n', 'c', auto_correct("correct"))
            map('i', '<C-g>', auto_correct("good"))
            map('n', 'g', auto_correct("good"))
            map('i', '<C-w>', auto_correct("wrong"))
            map('n', 'w', auto_correct("wrong"))
            map('i', '<C-s>', open_suggestions)
            map('n', 's', open_suggestions)
            map('i', '<C-f>', fix_all_errors())
            map('n', 'f', fix_all_errors())
            map('i', '<C-a>', fix_all_errors("buffer"))
            map('n', 'a', fix_all_errors("buffer"))

            -- Jump to the spell error when selected
            actions.select_default:replace(function()
                actions.close(prompt_bufnr)
                local selection = actions_state.get_selected_entry()
                vim.cmd("normal! m'")
                vim.api.nvim_win_set_cursor(0, {selection.value.line_num, selection.value.col_num})
                vim.cmd("normal! zz")
            end)
            return true
        end,
    })
    picker:find()
end

return require("telescope").register_extension {
    --- Setup function for the extension
    --- @param ext_config table Extension configuration
    --- @param config table Telescope configuration
    setup = function(ext_config, config)
        -- Get highlight groups
        local spell_bad = vim.api.nvim_get_hl(0, { name = "SpellBad" })
        local spell_cap = vim.api.nvim_get_hl(0, { name = "SpellCap" })
        local spell_rare = vim.api.nvim_get_hl(0, { name = "SpellRare" })
        local spell_local = vim.api.nvim_get_hl(0, { name = "SpellLocal" })

        -- Create hightlight groups (default, catppuccin, tokyonight use
        --  undercurls, `sp` is the color of the undercurl)
        vim.api.nvim_set_hl(0, hl_groups["_bad"], { fg = spell_bad.sp })
        vim.api.nvim_set_hl(0, hl_groups["_caps"], { fg = spell_cap.sp })
        vim.api.nvim_set_hl(0, hl_groups["_rare"], { fg = spell_rare.sp })
        vim.api.nvim_set_hl(0, hl_groups["_local"], { fg = spell_local.sp })
    end,
    exports = {
        spell_errors = telescope_spell_errors
    },
}
