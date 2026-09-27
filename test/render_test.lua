--- Тесты представления отказа наружу: вид RFC 9457 и простой вид.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.error.render')

--- Настройки представления.
---@param view string
---@return table
local function settings(view)
    return {
        view = view,
        type_base = 'urn:tnt-error:',
        instance_base = 'urn:tnt-incident:',
    }
end

--- Тело ответа для отказа с заданными полями.
---@param fields table
---@param view string|nil
---@return table
local function body(fields, view)
    local err = helper.part('tnt.error.failure').new(fields)

    return helper.part('tnt.error.render').of(err, settings(view or 'problem'))
end

g.test_expected_failure_fills_every_field_of_the_problem = function()
    t.assert_equals(
        body({
            code = 'customer.not_found',
            status = 404,
            title = 'Клиента №{id} нет',
            message = 'Клиента №7 нет',
        }),
        {
            type = 'urn:tnt-error:customer.not_found',
            title = 'Клиента №{id} нет',
            status = 404,
            detail = 'Клиента №7 нет',
            code = 'customer.not_found',
        }
    )
end

g.test_detail_is_left_out_when_it_repeats_the_title = function()
    -- У отказа без подстановок подробность дословно повторяет имя рода,
    -- и клиент получал бы одну и ту же фразу дважды.
    local shown = body({
        code = 'customer.forbidden',
        status = 403,
        title = 'Доступ закрыт',
        message = 'Доступ закрыт',
    })

    t.assert_equals(shown.detail, nil)
    t.assert_equals(shown.title, 'Доступ закрыт')
end

g.test_incident_goes_out_both_as_a_uri_and_as_it_reads_aloud = function()
    -- В URI его кладёт спецификация, а вслух человек называет короткий:
    -- выковыривать его из URI строковыми операциями клиент не должен.
    local shown = body({
        code = 'internal',
        status = 500,
        title = 'Внутренняя ошибка',
        message = 'Внутренняя ошибка. Назовите происшествие 4KJ7-QW9M.',
        incident = '4KJ7-QW9M',
    })

    t.assert_equals(shown.incident, '4KJ7-QW9M')
    t.assert_equals(shown.instance, 'urn:tnt-incident:4KJ7-QW9M')
end

g.test_a_declared_uri_of_the_kind_wins_over_the_built_one = function()
    -- Приложение, у которого есть страница с объяснением, обязано
    -- уметь на неё сослаться: собранный URN туда не ведёт.
    local shown = body({
        code = 'customer.not_found',
        status = 404,
        title = 'Нет',
        message = 'Нет',
        type = 'https://docs.example/errors/customer',
    })

    t.assert_equals(shown.type, 'https://docs.example/errors/customer')
end

g.test_simple_view_says_the_code_the_string_and_the_incident = function()
    t.assert_equals(
        body({
            code = 'internal',
            status = 500,
            title = 'Внутренняя ошибка',
            message = 'Внутренняя ошибка',
            incident = '4KJ7-QW9M',
        }, 'simple'),
        { error = 'internal', message = 'Внутренняя ошибка', incident = '4KJ7-QW9M' }
    )
end

g.test_views_are_listed_in_one_order = function()
    t.assert_equals(helper.part('tnt.error.render').NAMES, { 'problem', 'simple' })
end

g.test_every_view_is_signed_with_its_own_media_type = function()
    local kinds = helper.part('tnt.error.render').CONTENT_TYPE

    t.assert_equals(kinds.problem, 'application/problem+json')
    t.assert_equals(kinds.simple, 'application/json')
end

g.test_a_ready_view_is_known_by_its_name_and_nothing_else_is = function()
    local render = helper.part('tnt.error.render')

    t.assert_equals(render.knows('problem'), true)
    t.assert_equals(render.knows('simple'), true)
    t.assert_equals(render.knows('красиво'), false)
    t.assert_equals(render.knows(nil), false)
end

g.test_a_view_of_ones_own_gets_the_failure_and_the_settings = function()
    -- Пакет отдаёт своей функции всё, что у него есть: статус, код,
    -- опознаватель, подстановки — и не решает за неё, что из этого
    -- попадёт в тело.
    local err = helper.part('tnt.error.failure').new({
        code = 'customer.not_found',
        status = 404,
        title = 'Нет',
        message = 'Клиента №7 нет',
        incident = '4KJ7-QW9M',
    })

    local shown = helper.part('tnt.error.render').of(err, {
        view = function(given, given_settings)
            return {
                error = { status = given.status, message = given.message },
                where = given_settings.instance_base .. given.incident,
            }
        end,
        instance_base = 'urn:tnt-incident:',
    })

    t.assert_equals(shown, {
        error = { status = 404, message = 'Клиента №7 нет' },
        where = 'urn:tnt-incident:4KJ7-QW9M',
    })
end

g.test_a_view_without_a_name_is_called_custom_in_the_status = function()
    local render = helper.part('tnt.error.render')

    t.assert_equals(render.name_of('problem'), 'problem')
    t.assert_equals(
        render.name_of(function()
            return {}
        end),
        'custom'
    )
end

g.test_a_view_of_ones_own_is_signed_with_plain_json = function()
    -- Тело она отдаёт таблицей, а таблица уезжает тем же JSON, что
    -- и у простого вида; чем ещё её назвать, знает только автор.
    local render = helper.part('tnt.error.render')

    t.assert_equals(render.content_type_of('problem'), 'application/problem+json')
    t.assert_equals(render.content_type_of('simple'), 'application/json')
    t.assert_equals(
        render.content_type_of(function()
            return {}
        end),
        'application/json'
    )
end
