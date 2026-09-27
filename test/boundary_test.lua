--- Тесты стыка: отказ роутера, прошедший через каталог отказов.
---
--- Проверяется не пример в документе, а связка целиком — против исходников
--- обоих пакетов сразу. Договор границы HTTP объявлен в двух местах, и
--- разойтись эти два места могут молча: отказ роутера остаётся обычной
--- таблицей, а поймёт её или не поймёт каталог — видно только отсюда.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.routed_group('tnt.error.boundary')

--- Код ожидаемого отказа, которым отвечает обработчик маршрута.
local GONE = 'customer.gone'

--- Роутер, у которого вместо своих ответов стоит каталог отказов.
---
--- Ровно одной строкой — `on_error(errors.handler())`: именно это обещает
--- документ обоих пакетов, и именно это раньше превращало 404 в 500.
---@return any
local function routed()
    local r = g.router.new()

    r.get('/customers/:id', function(request)
        return nil, g.errors.new(GONE, { id = request.params.id })
    end)

    r.get('/orders', function()
        error('таблицы нет')
    end)

    r.post('/orders', function()
        return g.router.json({ ok = true })
    end)

    r.on_error(g.errors.handler())

    return r
end

g.before_each(function()
    g.errors.define(GONE, { status = 410, message = 'клиента №{id} больше нет' })
end)

g.test_a_missing_address_stays_a_404_and_does_not_become_a_breakage = function()
    local sent = routed().dispatch({ method = 'GET', path = '/нет-такого' })
    local shown = helper.body(sent)

    t.assert_equals(sent.status, 404)
    t.assert_equals(type(sent.body), 'string')
    t.assert_equals(shown.status, 404)
    t.assert_equals(shown.title, 'нет такого адреса')
    t.assert_equals(shown.code, g.errors.REFUSED)
    -- Опознаватель один и он роутера: каталог своего не выдавал и
    -- «внутренней поломки» не писал.
    t.assert_not_equals(shown.incident, helper.INCIDENT)
    t.assert_equals(helper.logged(shown.incident), true)
    t.assert_equals(helper.logged('внутренняя поломка'), false)
    t.assert_equals(helper.logged(helper.INCIDENT), false)
end

--- Случайность, выдающая байты 21, 22, 23 … сколько попросят.
---@param count integer
---@return string
local function counting(count)
    local bytes = {}

    for at = 1, count do
        bytes[at] = string.char(20 + at)
    end

    return table.concat(bytes)
end

g.test_the_router_writes_its_incident_by_the_same_agreement = function()
    -- Номера обоих пакетов стоят в одном поле одного ответа, и человек
    -- диктует их дежурному по телефону: вид у них обязан быть один.
    -- Договор записан в двух пакетах, и разойтись они могут только молча.
    helper.part('tnt.error.incident')._set_source({ random = counting })
    helper.part('tnt.router.errors')._set_source({ random = counting })

    local shown = helper.body(routed().dispatch({ method = 'GET', path = '/нет-такого' }))

    t.assert_equals(shown.incident, 'NPQR-STVW')
    t.assert_equals(helper.part('tnt.error.incident').next(), shown.incident)
end

g.test_a_wrong_method_stays_a_405_and_keeps_the_header_it_owes = function()
    -- Заголовок Allow при 405 требует RFC 9110 от ответа, а собирает ответ
    -- здесь каталог: заголовок, оставшийся у роутера, пропал бы молча.
    local sent = routed().dispatch({ method = 'DELETE', path = '/orders' })

    t.assert_equals(sent.status, 405)
    t.assert_equals(sent.headers.allow, 'GET, HEAD, OPTIONS, POST')
    -- Подпись ответа — того, кто собрал тело.
    t.assert_equals(sent.headers['content-type'], 'application/problem+json')
    t.assert_equals(helper.body(sent).title, 'этот способ здесь не поддерживается')
end

g.test_an_unparsed_request_stays_a_400 = function()
    -- Здесь запроса нет вовсе: он отвергнут до того, как стал запросом,
    -- и обработчику отказов достаётся один отказ без второго аргумента.
    local sent = routed().dispatch('GET /customers/7')

    t.assert_equals(sent.status, 400)
    t.assert_equals(type(sent.body), 'string')
    t.assert_equals(helper.body(sent).title, 'запрос не разобран')
end

g.test_a_fallen_handler_is_a_500_with_one_incident_and_one_record = function()
    local sent = routed().dispatch({ method = 'GET', path = '/orders' })
    local shown = helper.body(sent)

    t.assert_equals(sent.status, 500)
    t.assert_equals(shown.title, 'внутренняя ошибка')
    -- Причина живёт в журнале, а не в ответе.
    t.assert_equals(sent.body:find('таблицы нет', 1, true), nil)
    t.assert_equals(helper.logged('таблицы нет'), true)
    -- Запись одна, и номер в ответе ведёт именно к ней.
    t.assert_equals(helper.logged(shown.incident), true)
    t.assert_equals(helper.logged('внутренняя поломка'), false)
end

g.test_an_expected_refusal_of_the_handler_keeps_its_own_status_and_word = function()
    -- Договор читается в обе стороны: отказ, назвавший свой статус,
    -- при нём и остаётся. Прежде «клиента больше нет» отвечало 500 —
    -- роутер решал за обработчика, что его отказ это поломка узла.
    local sent = routed().dispatch({ method = 'GET', path = '/customers/7' })
    local shown = helper.body(sent)

    t.assert_equals(sent.status, 410)
    t.assert_equals(shown.code, GONE)
    t.assert_equals(shown.type, 'urn:tnt-error:' .. GONE)
    -- Слово доезжает целиком, с подстановкой; а вот шаблон, из которого
    -- оно собрано, — уже нет: договор границы несёт готовое слово, и
    -- имя рода отказа собирается из него же.
    t.assert_equals(shown.title, 'клиента №7 больше нет')
end

g.test_every_answer_carries_its_body_as_a_string = function()
    -- Таблица в теле уезжает клиенту как «table: 0x...»: `http.server`
    -- печатает её, а не собирает JSON.
    local r = routed()

    for _, asked in ipairs({
        { method = 'GET', path = '/нет-такого' },
        { method = 'DELETE', path = '/orders' },
        { method = 'GET', path = '/orders' },
        { method = 'GET', path = '/customers/7' },
    }) do
        t.assert_equals(type(r.dispatch(asked).body), 'string', asked.path)
    end
end
