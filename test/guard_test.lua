--- Тесты перехвата: паника, пара `nil, err` и запись о происшествии.

local json = require('json')
local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.error.guard')

g.before_each(function()
    helper.declare_customer(g.errors)
end)

g.test_a_call_that_went_well_gives_its_value_back = function()
    local value, err = g.errors.guard(function()
        return 'готово'
    end)

    t.assert_equals(value, 'готово')
    t.assert_equals(err, nil)
end

g.test_arguments_reach_the_called_function = function()
    local value = g.errors.guard(function(left, right)
        return left .. right
    end, 'пер', 'вое')

    t.assert_equals(value, 'первое')
end

g.test_a_pair_of_values_passes_through_as_it_is = function()
    -- Второе значение не всегда отказ: у `find` это ещё и позиция.
    local first, second = g.errors.guard(function()
        return 1, 4
    end)

    t.assert_equals({ first, second }, { 1, 4 })
end

g.test_panic_turns_into_a_breakage_with_an_incident = function()
    local value, err = g.errors.guard(function()
        -- Обращение к пустоте — самая частая поломка в Lua и самая
        -- обидная: ни один гейт её не ловит, а узел падает посреди
        -- запроса.
        local nothing = rawget({}, 'клиент')

        return nothing.field
    end)

    t.assert_equals(value, nil)
    t.assert_equals(g.errors.code_of(err), 'internal')
    t.assert_equals(g.errors.incident_of(err), helper.INCIDENT)
    t.assert_str_contains(err.message, helper.INCIDENT)
end

g.test_the_stack_is_kept_in_the_record_and_not_in_the_answer = function()
    -- По стеку видно устройство узла: имена файлов, номера строк, чужие
    -- библиотеки. Дежурному это нужно, клиенту — нет.
    local _, err = g.errors.guard(function()
        error('к базе не достучались')
    end)

    t.assert_str_contains(err.traceback, 'stack traceback')
    t.assert_equals(helper.logged('stack traceback'), true)
    t.assert_equals(helper.logged('к базе не достучались'), true)

    local body = g.errors.render(err)

    t.assert_equals(body.detail:find('traceback', 1, true), nil)
    t.assert_equals(body.detail:find('к базе', 1, true), nil)
end

g.test_the_stack_starts_where_it_broke = function()
    -- Ловушка снимает стек изнутри себя, и без поправки на это первой
    -- строкой в записи оказывается она сама — то есть чужое место,
    -- по которому о поломке не сказать ничего.
    local _, err = g.errors.guard(function()
        local nothing = rawget({}, 'клиент')

        return nothing.field
    end)

    local first = err.traceback:match('stack traceback:%s*([^\n]+)')

    t.assert_str_contains(first, 'guard_test.lua')
end

--- Стек, который несёт отказ соседа: кадр обработчика под кадром броска.
local CARRIED = "\nstack traceback:\n\t[C]: in function 'error'"
    .. '\n\tsrc/app/handlers.lua:12: in function <src/app/handlers.lua:10>'

--- Отказ соседа, поймавшего бросок сам: слово печатью, стек полем.
---@return table
local function fallen()
    return setmetatable({
        message = 'обработчик упал: src/app/handlers.lua:12: нет такого поля',
        traceback = CARRIED,
    }, {
        __tostring = function(self)
            return self.message
        end,
    })
end

g.test_a_breakage_that_brought_its_stack_keeps_it_in_the_record = function()
    -- Сосед поймал бросок сам и отдал его парой: снять стек здесь уже
    -- нечем, и без принесённого запись говорила бы, что сломалось, но
    -- не как туда пришли.
    local _, err = g.errors.guard(function()
        return nil, fallen()
    end)

    t.assert_equals(g.errors.code_of(err), 'internal')
    t.assert_equals(err.traceback, CARRIED)

    local record = helper.record()

    t.assert_equals(record.fields.traceback, CARRIED)
    -- Причина — слово соседа, без стека: стек лежит своим полем.
    t.assert_equals(
        record.fields.reason,
        'обработчик упал: src/app/handlers.lua:12: нет такого поля'
    )
end

g.test_the_stack_taken_here_goes_before_the_one_a_cause_brought = function()
    -- Снятый перехватом каталога — стек заведомо, а поле чужой таблицы —
    -- стек только по договору.
    local _, err = g.errors.guard(function()
        error(fallen())
    end)

    t.assert_str_contains(err.traceback, 'guard_test.lua:')
    t.assert_not_str_contains(err.traceback, 'src/app/handlers.lua')
end

g.test_only_a_string_is_taken_for_a_brought_stack = function()
    t.assert_equals(g.errors.of({ message = 'сломалось', traceback = 42 }).traceback, nil)
    t.assert_equals(g.errors.of({ message = 'сломалось', traceback = { CARRIED } }).traceback, nil)
    t.assert_equals(g.errors.of('сломалось').traceback, nil)

    -- Поле читается мимо метатаблицы: чужой `__index`, бросив, унёс бы
    -- с собой запись о поломке. Прямо через `internal` о чужой причине
    -- пишет и приложение, и описание причины такую таблицу уже переживает.
    local hostile = setmetatable({ message = 'сломалось' }, {
        __index = function()
            error('метатаблица бросила')
        end,
    })

    t.assert_equals(g.errors.registry():internal(hostile).traceback, nil)
    t.assert_equals(helper.logged('метатаблица бросила'), false)
end

g.test_an_expected_refusal_raised_on_purpose_passes_through_as_it_is = function()
    -- Прикладной код иногда бросает отказ вместо возврата пары: глубоко
    -- в разборе запроса возвращать пару не через что.
    local _, err = g.errors.guard(function()
        error(g.errors.new('customer.not_found', { id = 7 }))
    end)

    t.assert_equals(g.errors.is(err, 'customer.not_found'), true)
    t.assert_equals(err.status, 404)
    t.assert_equals(g.errors.incident_of(err), nil)
    -- Ожидаемый отказ не происшествие: в журнал о нём не пишут.
    t.assert_equals(helper.logged('внутренняя поломка'), false)
end

--- Отказ соседа, поймавшего бросок сам: брошенное лежит в нём полем
--- `raised`, как его бросили, — так устроен отказ упавшего шага
--- конвейера слоёв.
---@param raised any Что бросили
---@return table
local function caught_below(raised)
    local carrier = fallen()

    carrier.raised = raised

    return carrier
end

g.test_our_refusal_thrown_under_a_foreign_catch_passes_through_as_it_is = function()
    -- Конвейер слоёв ловит бросок обработчика раньше каталога и отдаёт
    -- его парой. Тот же отказ, пойманный самим `guard`, прошёл бы как
    -- есть — и пойманный соседом обязан отвечать собой, а не поломкой
    -- с номером происшествия.
    local refusal = g.errors.new('customer.not_found', { id = 7 })

    local _, err = g.errors.guard(function()
        return nil, caught_below(refusal)
    end)

    t.assert_is(err, refusal)
    t.assert_equals(g.errors.response(caught_below(refusal)).status, 404)
    t.assert_equals(helper.logged('внутренняя поломка'), false)
end

g.test_a_foreign_refusal_thrown_under_a_foreign_catch_keeps_its_status = function()
    local err = g.errors.of(caught_below({
        status = 409,
        message = 'счёт уже закрыт',
        headers = { ['retry-after'] = '5' },
    }))

    t.assert_equals(g.errors.code_of(err), g.errors.REFUSED)
    t.assert_equals(err.status, 409)
    t.assert_equals(err.message, 'счёт уже закрыт')
    t.assert_equals(err.headers, { ['retry-after'] = '5' })
    t.assert_equals(helper.logged('внутренняя поломка'), false)
end

g.test_what_was_thrown_without_a_sign_of_a_refusal_stays_a_breakage = function()
    -- Строка, таблица без статуса, статус не отказа — поломка, и причиной
    -- в записи идёт отказ соседа целиком: его слово называет упавший шаг,
    -- а стек лежит рядом.
    for _, raised in ipairs({ 'нет такого поля', { code = 'X' }, { status = 200 } }) do
        helper.forget()

        local err = g.errors.of(caught_below(raised))

        t.assert_equals(g.errors.code_of(err), 'internal')
        t.assert_equals(err.traceback, CARRIED)
        t.assert_equals(
            helper.reason(),
            'обработчик упал: src/app/handlers.lua:12: нет такого поля'
        )
    end
end

g.test_what_was_thrown_is_read_past_the_metatable = function()
    -- Чужой `__index` не подсовывает брошенного: о причине пишут там,
    -- где поломка уже случилась, и поле читается мимо метатаблицы.
    local refusal = g.errors.new('customer.not_found', { id = 7 })
    local lookalike = setmetatable({ message = 'сломалось' }, {
        __index = function(_, key)
            return key == 'raised' and refusal or nil
        end,
    })

    t.assert_equals(g.errors.code_of(g.errors.of(lookalike)), 'internal')
end

g.test_a_thrown_refusal_is_explained_and_wrapped_as_the_refusal_itself = function()
    local refusal = g.errors.new('customer.not_found', { id = 7 })

    local explained = g.errors.explain(caught_below(refusal), 'Такого клиента у нас нет')

    t.assert_equals(explained.status, 404)
    t.assert_is(explained.cause, refusal)

    g.errors.define('order.lost', { status = 410, message = 'Заказа больше нет' })

    t.assert_is(g.errors.wrap(caught_below(refusal), 'order.lost').cause, refusal)
    t.assert_equals(helper.logged('внутренняя поломка'), false)
end

g.test_a_pair_with_a_foreign_refusal_is_brought_to_the_common_shape = function()
    local value, err = g.errors.guard(function()
        return nil, 'адрес сервера SMTP не задан'
    end)

    t.assert_equals(value, nil)
    t.assert_equals(g.errors.code_of(err), 'internal')
    t.assert_equals(helper.logged('адрес сервера SMTP не задан'), true)
end

g.test_a_pair_with_our_own_refusal_keeps_it = function()
    local _, err = g.errors.guard(function()
        return nil, g.errors.new('customer.not_found', { id = 7 })
    end)

    t.assert_equals(g.errors.is(err, 'customer.not_found'), true)
end

g.test_secrets_do_not_reach_the_record_of_the_incident = function()
    g.errors.of('к базе не достучались: postgres://root:hunter2@db')

    t.assert_equals(helper.logged('hunter2'), false)
    t.assert_equals(helper.logged('postgres://root:[скрыто]@db'), true)
end

g.test_a_plain_table_cause_is_told_in_the_record_by_its_fields = function()
    -- Номер происшествия ведёт в запись, и `table: 0x…` в ней не говорил,
    -- что сломалось у источника. Тайна при этом прячется по имени ключа.
    local err = g.errors.of({ code = 'X', password = 'p' })

    t.assert_equals(json.decode(helper.reason()), { code = 'X', password = '[скрыто]' })
    t.assert_equals(helper.logged('table: 0x'), false)
    -- Сырое поле, а не строка plain: в ней кавычки экранированы,
    -- и `"p"` не нашёлся бы, даже уехав в запись.
    t.assert_not_str_contains(helper.reason(), '"p"')
    -- Цепочка отказа говорит о причине то же, что и запись.
    t.assert_equals(err.cause, helper.reason())
    t.assert_str_contains(tostring(err), '"code":"X"')
end

g.test_a_separate_catalogue_tells_a_table_cause_the_same_way = function()
    -- Так пишет о чужой причине приложение со своим каталогом: прямо
    -- через `internal`, мимо `of`.
    g.errors.registry():internal({ message = 'узел не ответил', nodes = { 'a', 'b' } })

    t.assert_equals(json.decode(helper.reason()), { message = 'узел не ответил', nodes = { 'a', 'b' } })
end

g.test_every_breakage_gets_its_own_record = function()
    -- Запись делается там, где поломку завели, а не там, где показали:
    -- показать её могут и не захотеть, а происшествие всё равно было.
    local err = g.errors.of('сервер молчит')

    t.assert_equals(helper.logged(helper.INCIDENT), true)
    t.assert_equals(g.errors.incident_of(err), helper.INCIDENT)
end
