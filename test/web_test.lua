--- Тесты слоя и обработчика: что уедет клиенту вместо отказа.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.error.web')

g.before_each(function()
    helper.declare_customer(g.errors)
end)

g.test_layer_lets_a_good_answer_through_untouched = function()
    local answered = g.errors.middleware()({ path = '/customers/7' }, function(request)
        return { status = 200, body = request.path }
    end)

    t.assert_equals(answered, { status = 200, body = '/customers/7' })
end

g.test_layer_turns_an_expected_refusal_into_its_own_answer = function()
    local answered = g.errors.middleware()({}, function()
        return nil, g.errors.new('customer.not_found', { id = 7 })
    end)

    t.assert_equals(answered.status, 404)
    t.assert_equals(answered.headers, { ['content-type'] = 'application/problem+json' })
    t.assert_equals(helper.body(answered).detail, 'Клиента №7 нет')
end

g.test_layer_hides_a_breakage_behind_an_incident = function()
    local answered = g.errors.middleware()({}, function()
        error('к базе не достучались: postgres://root:hunter2@db')
    end)

    local shown = helper.body(answered)

    t.assert_equals(answered.status, 500)
    t.assert_equals(shown.incident, helper.INCIDENT)
    -- Ни адреса, ни пароля, ни слова о том, что именно сломалось.
    t.assert_equals(shown.detail:find('hunter2', 1, true), nil)
    t.assert_equals(shown.detail:find('postgres', 1, true), nil)
    t.assert_equals(helper.logged(helper.INCIDENT), true)
end

g.test_a_foreign_text_in_a_pair_does_not_reach_the_client = function()
    -- Строка из пары `nil, err` писалась для дежурного: в ней путь,
    -- имя пользователя базы и ответ чужого сервера целиком.
    local answered = g.errors.middleware()({}, function()
        return nil, 'отправлять некуда: адрес сервера SMTP не задан'
    end)

    t.assert_equals(answered.status, 500)
    t.assert_equals(helper.body(answered).detail:find('SMTP', 1, true), nil)
end

g.test_handler_turns_anything_at_all_into_an_answer = function()
    local answered = g.errors.handler()(g.errors.new('customer.not_found', { id = 7 }))

    t.assert_equals(answered.status, 404)
    t.assert_equals(helper.body(answered).code, 'customer.not_found')

    t.assert_equals(g.errors.handler()('сервер молчит').status, 500)
end

g.test_handler_keeps_the_status_and_the_headers_of_a_foreign_refusal = function()
    -- Ровно то, ради чего договор границы и заведён: обработчик
    -- подставляется в `router.on_error` одной строкой, а 405 соседа
    -- остаётся 405 — вместе с заголовком Allow, которого требует RFC 9110.
    local answered = g.errors.handler()({
        status = 405,
        message = 'этот способ здесь не поддерживается',
        incident = 'ROUTER-1',
        headers = { allow = 'GET, HEAD, OPTIONS' },
    }, { method = 'POST', path = '/customers' })

    t.assert_equals(answered.status, 405)
    t.assert_equals(answered.headers.allow, 'GET, HEAD, OPTIONS')
    -- Подпись ответа остаётся за тем, кто собрал тело.
    t.assert_equals(answered.headers['content-type'], 'application/problem+json')

    local shown = helper.body(answered)

    t.assert_equals(shown.title, 'этот способ здесь не поддерживается')
    t.assert_equals(shown.status, 405)
    t.assert_equals(shown.incident, 'ROUTER-1')
    -- Своего опознавателя пакет не выдавал, и о поломке не писал.
    t.assert_equals(helper.logged(helper.INCIDENT), false)
    t.assert_equals(helper.logged('внутренняя поломка'), false)
end

g.test_both_pass_the_request_on_so_the_browser_gets_a_page = function()
    -- Вид ответа выбирает сам запрос, и дойти до каталога он обязан
    -- обеими дорогами: и слоем, и обработчиком отказов роутера.
    local browser = { method = 'GET', path = '/customers/7', headers = { accept = 'text/html' } }

    local layered = g.errors.middleware()(browser, function()
        return nil, g.errors.new('customer.not_found', { id = 7 })
    end)

    t.assert_equals(layered.status, 404)
    t.assert_equals(layered.headers['content-type'], 'text/html; charset=utf-8')
    t.assert_str_contains(layered.body, '<p>Клиента №7 нет</p>')

    local handled = g.errors.handler()({ status = 404, message = 'нет такого адреса' }, browser)

    t.assert_equals(handled.headers['content-type'], 'text/html; charset=utf-8')
    t.assert_str_contains(handled.body, '<p>нет такого адреса</p>')

    -- А тот же отказ без запроса — прежним телом: страницу просят,
    -- а не получают по умолчанию.
    t.assert_equals(g.errors.handler()({ status = 404 }).headers['content-type'], 'application/problem+json')
end
