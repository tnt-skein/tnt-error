--- Тесты описания причины: таблица полями, тайны, кольцо, пределы, печать.

local ffi = require('ffi')
local json = require('json')
local t = require('luatest')
local utf8 = require('utf8')
local uuid = require('uuid')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.error.describe')

--- Сборка ошибок Tarantool: конструктор в аннотациях описан не полностью,
--- поэтому берётся через промежуточную ссылку.
---@type any
local box_error = box.error

--- Чем помечено описание, в которое вошли не все пары.
local CUT = '…'

--- Что ставится вместо таблицы глубже предела.
local DEEP = '[глубже]'

--- Модуль тайн, в котором живёт описание причины.
---@return any
local function secret()
    return helper.part('tnt.error.secret')
end

--- Описание причины.
---@param value any
---@return string
local function describe(value)
    return secret().describe(value)
end

--- Описание, разобранное обратно в таблицу: порядок пар у таблицы
--- не задан, и сверять текст JSON целиком нельзя.
---@param value any
---@return any
local function outline(value)
    return json.decode(describe(value))
end

--- Обрезанное описание без отметки, разобранное в таблицу.
---@param said string
---@return any
local function uncut(said)
    t.assert_equals(said:sub(-#CUT), CUT, 'описание не помечено обрезанным')

    return json.decode(said:sub(1, -#CUT - 1))
end

--- Цепочка вложенных таблиц: верхняя — первый уровень, в самой нижней
--- лежит `leaf`.
---@param levels integer
---@return table
local function chain(levels)
    local top = {}
    local at = top

    for _ = 2, levels do
        at.inner = {}
        at = at.inner
    end

    at.leaf = true

    return top
end

--- Что лежит на заданном уровне разобранной цепочки.
---@param shown any
---@param number integer
---@return any
local function level(shown, number)
    local at = shown

    for _ = 2, number do
        at = at.inner
    end

    return at
end

--- Таблица из заданного числа пар.
---@param count integer
---@return table
local function wide(count)
    local cause = {}

    for number = 1, count do
        cause['key' .. number] = number
    end

    return cause
end

--- Сколько пар в таблице на всех уровнях вместе.
---@param value any
---@return integer
local function counted(value)
    local total = 0

    for _, inner in pairs(value) do
        total = total + 1

        if type(inner) == 'table' then
            total = total + counted(inner)
        end
    end

    return total
end

--- Таблица, которая печатает себя заданной функцией.
---@param fields table
---@param print_as function
---@return table
local function printing(fields, print_as)
    return setmetatable(fields, { __tostring = print_as })
end

--- Печать, которая бросает.
local function broken_print()
    error('печати нет')
end

g.test_the_limits_are_the_ones_the_document_names = function()
    t.assert_equals(secret().DEPTH, 8)
    t.assert_equals(secret().ENTRIES, 64)
end

g.test_a_plain_table_is_told_by_its_fields_and_not_by_its_address = function()
    -- Отказ соседа без `__tostring` печатался адресом, и номер
    -- происшествия вёл в запись, из которой не понять, что сломалось.
    local cause = { message = 'узел не ответил', code = 'storage.down' }

    t.assert_equals(outline(cause), cause)
    t.assert_not_str_contains(describe(cause), 'table: 0x')
end

g.test_a_nested_table_is_told_level_by_level = function()
    local cause = { error = { code = 'X', details = { 'первое', 'второе' } }, status = 'bad' }

    t.assert_equals(outline(cause), cause)
    -- Массив остаётся массивом: целые ключи не становятся строками.
    t.assert_str_contains(describe(cause), '["первое","второе"]')
end

g.test_a_value_under_a_secret_name_is_hidden_before_encoding = function()
    -- Поддерево под именем тайны прячется целиком: в тексте JSON имя
    -- и значения — уже просто соседние слова.
    local cause = { code = 'X', password = 'p', db = { token = { 'часть', 'тайны' }, host = 'db' } }

    t.assert_equals(outline(cause), {
        code = 'X',
        password = secret().HIDDEN,
        db = { token = secret().HIDDEN, host = 'db' },
    })
end

g.test_a_password_inside_a_string_field_is_hidden_too = function()
    t.assert_equals(
        outline({ url = 'postgres://root:hunter2@db/main' }),
        { url = 'postgres://root:' .. secret().HIDDEN .. '@db/main' }
    )
end

g.test_a_table_pointing_at_itself_is_told_without_taking_the_node_down = function()
    local ring = { id = 7 }

    ring.self = ring

    t.assert_equals(outline(ring), { id = 7, self = secret().CYCLE })
end

g.test_the_same_table_in_two_fields_is_told_twice = function()
    -- Кольцо — это ссылка внутрь себя, а не две ссылки на одно и то же.
    local shared = { host = 'db' }

    t.assert_equals(outline({ left = shared, right = shared }), { left = { host = 'db' }, right = { host = 'db' } })
end

g.test_a_table_is_told_down_to_the_depth_limit_and_marked_below = function()
    local limit = secret().DEPTH

    t.assert_equals(level(outline(chain(limit)), limit), { leaf = true })
    t.assert_equals(level(outline(chain(limit + 1)), limit), { inner = DEEP })
end

g.test_a_very_deep_table_does_not_take_the_node_down = function()
    -- `json` бросает на сто двадцать девятом уровне, а обход без предела
    -- на такой глубине переполнил бы стек.
    local limit = secret().DEPTH

    t.assert_equals(level(outline(chain(100000)), limit), { inner = DEEP })
end

g.test_a_table_at_the_limit_of_pairs_is_told_whole = function()
    local cause = wide(secret().ENTRIES)
    local said = describe(cause)

    t.assert_equals(json.decode(said), cause)
    t.assert_not_str_contains(said, CUT)
end

g.test_a_longer_table_is_cut_at_the_limit_and_marked = function()
    t.assert_equals(counted(uncut(describe(wide(secret().ENTRIES + 1)))), secret().ENTRIES)
    -- Широкая таблица не копируется целиком ради строки, которую журнал
    -- всё равно обрежет.
    t.assert_equals(counted(uncut(describe(wide(100000)))), secret().ENTRIES)
end

g.test_the_limit_of_pairs_is_shared_by_all_levels = function()
    local said = describe({ first = wide(40), second = wide(40) })

    t.assert_equals(counted(uncut(said)), secret().ENTRIES)
end

g.test_a_long_field_is_cut_by_the_window_without_breaking_a_letter = function()
    -- Окно вырезания тайн — 8192 байта: дальше образцы не ходят, и хвост
    -- за ним не отдаётся.
    local said = describe({ text = string.rep('я', 5000) })

    t.assert_equals(said:sub(-#CUT), CUT)
    t.assert_le(#said, 8192 + #CUT)
    t.assert_not_equals(utf8.len(said), nil)
end

g.test_keys_json_does_not_take_become_their_print = function()
    t.assert_equals(
        outline({ [true] = 'да', [1.5] = 'полтора', [math.huge] = 'много' }),
        { ['true'] = 'да', ['1.5'] = 'полтора', inf = 'много' }
    )
end

g.test_an_integer_key_stays_a_number_while_double_holds_it_exactly = function()
    local exact = 2 ^ 53

    t.assert_equals(
        outline({ [exact] = 'точно', [-exact] = 'точно ниже', [exact + 2] = 'уже нет' }),
        {
            ['9007199254740992'] = 'точно',
            ['-9007199254740992'] = 'точно ниже',
            ['9.007199254741e+15'] = 'уже нет',
        }
    )
end

g.test_a_key_printed_as_a_secret_name_is_hidden_as_well = function()
    local name = printing({}, function()
        return 'password'
    end)

    t.assert_equals(outline({ [name] = 'hunter2' }), { password = secret().HIDDEN })
end

g.test_a_key_that_cannot_be_printed_is_told_by_its_kind = function()
    t.assert_equals(
        outline({ [printing({}, broken_print)] = 'значение' }),
        { ['[table]'] = 'значение' }
    )
end

g.test_numbers_and_flags_stay_what_they_are = function()
    local cause = { count = 42, share = 1.5, done = true, failed = false }

    t.assert_equals(outline(cause), cause)
    t.assert_str_contains(describe({ broken = 0 / 0 }), '"broken":nan')
end

g.test_values_json_writes_itself_stay_values = function()
    local said = describe({ nothing = box.NULL, signed = -5LL, unsigned = 5ULL })

    t.assert_str_contains(said, '"nothing":null')
    t.assert_str_contains(said, '"signed":-5')
    t.assert_str_contains(said, '"unsigned":5')
end

g.test_values_json_cannot_write_become_their_print = function()
    -- Пустой указатель не того рода равен `nil`, но `json` его не берёт.
    local pointer = ffi.new('int *')
    local address = ffi.cast('void *', 1)
    local id = uuid.fromstr('6ba7b810-9dad-11d1-80b4-00c04fd430c8')
    local shown = outline({ call = print, pointer = pointer, address = address, id = id })

    t.assert_str_matches(shown.call, 'function: .+')
    t.assert_equals(shown.pointer, 'cdata<int *>: NULL')
    t.assert_equals(shown.address, tostring(address))
    t.assert_equals(shown.id, '6ba7b810-9dad-11d1-80b4-00c04fd430c8')
end

g.test_a_value_that_cannot_be_printed_is_told_by_its_kind = function()
    local throwing = newproxy(true)
    local wordless = newproxy(true)

    getmetatable(throwing).__tostring = broken_print
    -- Печать не строкой в LuaJIT законна, и она не лучше сломанной.
    getmetatable(wordless).__tostring = function()
        return 42
    end

    t.assert_equals(outline({ throwing = throwing, wordless = wordless }), {
        throwing = '[userdata]',
        wordless = '[userdata]',
    })
end

g.test_a_nested_table_that_prints_itself_is_told_by_its_print = function()
    local inner = printing({ internals = 'x' }, function()
        return 'печатается сам'
    end)

    t.assert_equals(outline({ inner = inner }), { inner = 'печатается сам' })
end

g.test_a_table_whose_print_breaks_is_told_by_its_fields = function()
    -- Поля скажут о ней больше, чем пустая отметка.
    local broken = printing({ code = 'X' }, broken_print)
    local wordless = printing({ code = 'Y' }, function()
        return 42
    end)

    t.assert_equals(outline(broken), { code = 'X' })
    t.assert_equals(outline({ inner = broken }), { inner = { code = 'X' } })
    t.assert_equals(outline(wordless), { code = 'Y' })
end

g.test_a_table_without_its_own_print_is_told_by_its_fields = function()
    local object = setmetatable({ code = 'X' }, { __index = {} })
    -- Закрытая метатаблица не показывает, есть ли печать, и таблица
    -- описывается полями.
    local closed = setmetatable({ code = 'Y' }, {
        __metatable = 'закрыто',
        __tostring = function()
            return 'печатается сам'
        end,
    })

    t.assert_equals(outline(object), { code = 'X' })
    t.assert_equals(outline(closed), { code = 'Y' })
end

g.test_a_binary_string_is_replaced_by_its_length = function()
    -- Журнал заменяет негодную строку поля целиком, и одно двоичное поле
    -- стёрло бы из записи всё описание.
    t.assert_equals(
        outline({ blob = '\xff\xfe', ['\xff'] = 'ключ' }),
        { blob = '[не UTF-8, 2 байт]', ['[не UTF-8, 1 байт]'] = 'ключ' }
    )
    t.assert_equals(describe('\xff\xfe\xfd'), '[не UTF-8, 3 байт]')
end

g.test_what_prints_itself_stays_its_print = function()
    local told = printing({ internals = 'x' }, function()
        return 'вход не вышел: token=abc'
    end)

    t.assert_equals(describe('сервер молчит'), 'сервер молчит')
    t.assert_equals(describe(nil), 'nil')
    t.assert_equals(describe(42), '42')
    t.assert_equals(describe(false), 'false')
    t.assert_equals(describe(5LL), '5LL')
    t.assert_equals(
        describe(box_error.new({ reason = 'к базе не достучались', code = 1 })),
        'к базе не достучались'
    )
    -- Тайны прячутся и в печати: её тоже никто не проверял.
    t.assert_equals(describe(told), 'вход не вышел: token=' .. secret().HIDDEN)
end
