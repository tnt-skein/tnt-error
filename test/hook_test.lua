--- Тесты крюков внутренней поломки: постановка, порядок, снятие, что
--- крюк получает и что бывает, когда он срывается.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.error.hook')

--- Крюк, который складывает услышанное в список.
---@param heard table[]
---@param name string|nil Чем подписать услышанное
---@return fun(failure: table, cause: any)
local function listener(heard, name)
    return function(failure, cause)
        table.insert(heard, { name = name, failure = failure, cause = cause })
    end
end

--- Текст исключения от `hook` и место, на которое оно должно указывать:
--- строка вызова в этом файле.
---@param ... any Аргументы `hook`
---@return string err
---@return string place
local function raised(...)
    local call = { n = select('#', ...), ... }
    local line
    local ok, err = pcall(function()
        line = assert(debug.getinfo(1, 'l')).currentline + 1
        g.errors.hook(unpack(call, 1, call.n))
    end)

    t.assert_equals(ok, false, 'вызов должен был бросить')

    return tostring(err), ('hook_test.lua:%d: '):format(line)
end

g.test_a_hook_hears_the_breakage_with_its_incident_stack_and_cause = function()
    local heard = {}
    local cause = { code = 'storage.down', password = 'hunter2' }

    g.errors.hook('alert', listener(heard))

    local err = g.errors.of(cause)

    t.assert_equals(#heard, 1)
    -- Слушатель получает тот самый отказ, что ушёл вызывающему, и причину
    -- как есть — той же таблицей, с тайной: описание причины в отказе —
    -- строка для журнала, а слушателю со своим разбором нужна она сама.
    t.assert_is(heard[1].failure, err)
    t.assert_is(heard[1].cause, cause)
    t.assert_equals(heard[1].failure.incident, helper.INCIDENT)
    t.assert_equals(heard[1].failure.code, g.errors.INTERNAL)
end

g.test_a_hook_hears_after_the_record_is_made = function()
    -- Номер обязан вести в журнал к тому мигу, когда о нём узнал слушатель:
    -- иначе событие приёмника указывало бы на запись, которой ещё нет.
    local recorded

    g.errors.hook('alert', function()
        recorded = helper.logged('внутренняя поломка')
    end)

    g.errors.of('сервер молчит')

    t.assert_equals(recorded, true)
end

g.test_a_panic_under_guard_reaches_the_hook_with_the_stack_of_the_place = function()
    local heard = {}

    g.errors.hook('alert', listener(heard))

    local _, err = g.errors.guard(function()
        error('к базе не достучались', 0)
    end)

    t.assert_equals(heard[1].cause, 'к базе не достучались')
    t.assert_is(heard[1].failure, err)
    t.assert_str_contains(heard[1].failure.traceback, 'hook_test.lua')
end

g.test_hooks_hear_every_catalog_of_the_process = function()
    -- Каталоги заводятся и внутри пакетов, до которых приложение
    -- не дотягивается: крюк одного каталога их поломок не услышал бы.
    local heard = {}

    g.errors.hook('alert', listener(heard))
    g.errors.registry():internal('поломка своего каталога')

    t.assert_equals(#heard, 1)
    t.assert_equals(heard[1].cause, 'поломка своего каталога')
end

g.test_expected_refusals_and_refusals_of_the_boundary_are_not_breakages = function()
    local heard = {}

    helper.declare_customer(g.errors)
    g.errors.hook('alert', listener(heard))

    g.errors.new('customer.not_found', { id = 7 })
    g.errors.of({ status = 404, message = 'нет такого адреса' })
    g.errors.of({ status = 503, incident = '1111-1111' })

    -- Об отказе границы с номером уже написал отказавший: второй записи
    -- нет, и слушателю о нём не сообщается.
    t.assert_equals(heard, {})
end

g.test_hooks_are_called_in_the_order_they_were_set = function()
    local heard = {}

    g.errors.hook('first', listener(heard, 'first'))
    g.errors.hook('second', listener(heard, 'second'))
    g.errors.of('сервер молчит')

    t.assert_equals(g.errors.hooks(), { 'first', 'second' })
    t.assert_equals({ heard[1].name, heard[2].name }, { 'first', 'second' })
end

g.test_a_replaced_hook_keeps_its_place = function()
    local heard = {}

    g.errors.hook('first', listener(heard, 'прежний'))
    g.errors.hook('second', listener(heard, 'second'))
    g.errors.hook('first', listener(heard, 'новый'))
    g.errors.of('сервер молчит')

    t.assert_equals(g.errors.hooks(), { 'first', 'second' })
    t.assert_equals({ heard[1].name, heard[2].name }, { 'новый', 'second' })
    t.assert_equals(#heard, 2)
end

g.test_a_removed_hook_hears_nothing_and_comes_back_last = function()
    local heard = {}

    g.errors.hook('first', listener(heard, 'first'))
    g.errors.hook('second', listener(heard, 'second'))
    g.errors.hook('third', listener(heard, 'third'))
    g.errors.hook('second', nil)

    t.assert_equals(g.errors.hooks(), { 'first', 'third' })

    g.errors.of('сервер молчит')

    t.assert_equals({ heard[1].name, heard[2].name, #heard }, { 'first', 'third', 2 })

    g.errors.hook('second', listener(heard, 'second'))

    t.assert_equals(g.errors.hooks(), { 'first', 'third', 'second' })
end

g.test_removing_a_hook_that_is_not_there_changes_nothing = function()
    g.errors.hook('first', listener({}))
    g.errors.hook('absent', nil)

    t.assert_equals(g.errors.hooks(), { 'first' })
end

g.test_the_list_of_hooks_is_a_copy = function()
    g.errors.hook('first', listener({}))
    table.insert(g.errors.hooks(), 'чужое')

    t.assert_equals(g.errors.hooks(), { 'first' })
end

g.test_a_failing_hook_costs_neither_the_failure_nor_the_other_hooks = function()
    local heard = {}

    g.errors.hook('broken', function()
        error('приёмник упал', 0)
    end)
    g.errors.hook('alert', listener(heard))

    local err = g.errors.of('сервер молчит')

    t.assert_equals(g.errors.code_of(err), g.errors.INTERNAL)
    t.assert_equals(#heard, 1)
    t.assert_equals(helper.fields('крюк внутренней поломки «broken» не отработал'), {
        incident = helper.INCIDENT,
        err = 'приёмник упал',
    })
end

g.test_a_bad_name_is_blamed_on_the_caller = function()
    local hook = listener({})
    local err, place = raised(nil, hook)

    t.assert_str_contains(err, place .. 'имя крюка — непустая строка, а не nil')
    t.assert_str_contains(
        (raised('', hook)),
        'имя крюка — непустая строка, а не пустая'
    )
    t.assert_str_contains((raised(7, hook)), 'имя крюка — непустая строка, а не number')
end

g.test_a_hook_that_is_not_a_function_is_blamed_on_the_caller = function()
    local err, place = raised('alert', 'print')

    t.assert_str_contains(err, place .. 'крюк — функция, а не string')
    t.assert_equals(g.errors.hooks(), {})
end
