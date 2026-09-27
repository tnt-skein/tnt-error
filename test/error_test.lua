--- Тесты фасада отказов: объявление, заведение, обёртка, ответ.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.error')

g.before_each(function()
    helper.declare_customer(g.errors)
end)

--- Отказ «нет такого клиента» с подстановкой.
---@param id any
---@return any
local function missing(id)
    return g.errors.new('customer.not_found', { id = id })
end

g.test_declared_failure_comes_out_with_its_code_status_and_string = function()
    local err = missing(7)

    t.assert_equals(g.errors.code_of(err), 'customer.not_found')
    t.assert_equals(err.status, 404)
    t.assert_equals(err.message, 'Клиента №7 нет')
    t.assert_equals(g.errors.expected(err), true)
    -- Ожидаемый отказ не происшествие: искать в журнале нечего.
    t.assert_equals(g.errors.incident_of(err), nil)
end

g.test_define_gives_the_code_back_to_be_kept_in_a_variable = function()
    local code = g.errors.define('mail.not_sent', { status = 502, message = 'Не ушло' })

    t.assert_equals(code, 'mail.not_sent')
    t.assert_equals(g.errors.defined('mail.not_sent').status, 502)
    t.assert_equals(g.errors.defined('mail.never_declared'), nil)
end

g.test_internal_breakage_is_declared_from_the_start = function()
    -- Без него нечем ответить на первую же панику, а объявлять его
    -- каждому приложению самому значит завести двадцать разных.
    t.assert_equals(g.errors.codes(), { 'customer.not_found', 'internal' })
    t.assert_equals(g.errors.defined(g.errors.INTERNAL).status, 500)
end

g.test_a_failure_nobody_declared_is_refused_at_once = function()
    -- Опечатка в коде иначе доживает до клиента и превращается в ответ
    -- о чужом отказе.
    helper.refuses(function()
        g.errors.new('customer.not_fond', { id = 7 })
    end, 'отказ customer.not_fond не объявлен')
end

g.test_only_our_own_failure_answers_to_a_code = function()
    t.assert_equals(g.errors.is(missing(7), 'customer.not_found'), true)
    t.assert_equals(g.errors.is(missing(7), 'internal'), false)
    t.assert_equals(g.errors.is('сервер молчит', 'internal'), false)
    t.assert_equals(g.errors.is(nil, nil), false)
    t.assert_equals(g.errors.code_of('сервер молчит'), nil)
    t.assert_equals(g.errors.expected('сервер молчит'), false)
end

g.test_secrets_in_the_substitutions_never_reach_the_string = function()
    g.errors.define('auth.failed', { status = 401, message = 'Вход не вышел: {password}' })

    local err = g.errors.new('auth.failed', { password = 'hunter2' })

    t.assert_equals(err.message, 'Вход не вышел: [скрыто]')
    t.assert_equals(err.params.password, '[скрыто]')
end

g.test_a_hostile_substitution_or_cause_does_not_hang_the_node = function()
    -- Строку `@a:=a:=…` без `@` в конце образец адреса разбирал заново
    -- с каждого `=`: 64 КБ в подстановке держали узел одиннадцать секунд.
    -- Предел в пятьдесят миллисекунд отличает линейный проход от такого
    -- и на занятой машине.
    local clock = require('clock')
    local hostile = '@' .. string.rep('a:=', 21845)
    local started = clock.monotonic()
    local substituted = g.errors.new('customer.not_found', { id = hostile })
    local caused = g.errors.of(hostile)

    t.assert_lt(clock.monotonic() - started, 0.05)
    -- Длиннее окна вырезания строка не отдаётся: непроверенный хвост мог
    -- нести тайну.
    t.assert_equals(substituted.params.id, hostile:sub(1, 8192) .. '…')
    t.assert_str_contains(tostring(caused), hostile:sub(1, 8192) .. '…')
end

g.test_a_foreign_refusal_becomes_a_breakage_and_keeps_its_text_inside = function()
    local err = g.errors.of('к базе не достучались')

    t.assert_equals(g.errors.code_of(err), 'internal')
    t.assert_equals(g.errors.expected(err), false)
    t.assert_equals(g.errors.incident_of(err), helper.INCIDENT)
    -- Наружу пойдёт message, и чужого текста в нём нет; текст остался
    -- в цепочке, которую читает только журнал.
    t.assert_equals(err.message:find('к базе', 1, true), nil)
    t.assert_str_contains(tostring(err), 'к базе не достучались')
end

g.test_a_foreign_refusal_of_the_boundary_is_taken_as_it_came = function()
    -- Договор границы HTTP: статус, слово, код, опознаватель и заголовки
    -- приезжают с отказом и остаются при нём. Без этого 404 роутера
    -- становился внутренней поломкой со вторым номером и второй записью.
    local err = g.errors.of({
        status = 405,
        message = 'этот способ здесь не поддерживается',
        code = 'router.method',
        incident = 'ЧУЖОЙ-1',
        headers = { allow = 'GET, HEAD, OPTIONS' },
    })

    t.assert_equals(err.status, 405)
    t.assert_equals(err.message, 'этот способ здесь не поддерживается')
    t.assert_equals(err.title, 'этот способ здесь не поддерживается')
    t.assert_equals(g.errors.code_of(err), 'router.method')
    t.assert_equals(g.errors.incident_of(err), 'ЧУЖОЙ-1')
    t.assert_equals(err.headers, { allow = 'GET, HEAD, OPTIONS' })
    -- Своего опознавателя пакет не выдавал и о поломке не писал.
    t.assert_equals(helper.logged(helper.INCIDENT), false)
    t.assert_equals(helper.logged('внутренняя поломка'), false)
end

g.test_a_foreign_refusal_that_said_nothing_gets_our_own_word = function()
    local silent = g.errors.of({ status = 404 })

    t.assert_equals(g.errors.code_of(silent), g.errors.REFUSED)
    t.assert_equals(silent.message, 'Запрос отклонён')

    -- Слово и код не той породы — всё равно что не сказанные: таблица
    -- уехала бы клиенту как есть, а сказать человеку ей нечего.
    local odd = g.errors.of({ status = 404, message = { 'нет' }, code = 42 })

    t.assert_equals(odd.message, 'Запрос отклонён')
    t.assert_equals(g.errors.code_of(odd), g.errors.REFUSED)
end

g.test_a_foreign_refusal_is_expected_below_five_hundred_and_broken_above = function()
    -- 4xx — «так бывает», 5xx — «так быть не должно», и спрашивающему
    -- `expected` важна именно эта разница, а не то, кто собрал отказ.
    t.assert_equals(g.errors.expected(g.errors.of({ status = 400 })), true)
    t.assert_equals(g.errors.expected(g.errors.of({ status = 499 })), true)
    t.assert_equals(g.errors.expected(g.errors.of({ status = 500 })), false)
    t.assert_equals(g.errors.expected(g.errors.of({ status = 599 })), false)
end

g.test_secrets_in_a_foreign_word_are_cut_out_too = function()
    local err = g.errors.of({ status = 400, message = 'не вошли по ключу /enter?token=abc123' })

    t.assert_equals(err.message, 'не вошли по ключу /enter?token=[скрыто]')
end

g.test_a_word_over_a_foreign_refusal_keeps_the_headers_the_status_owes = function()
    -- Слово поменялось, а `Allow` при 405 по-прежнему требует RFC 9110 —
    -- и требует он его от ответа, а не от того, кто первым его собрал.
    local err = g.errors.explain({ status = 405, headers = { allow = 'GET' } }, 'сюда так нельзя')

    t.assert_equals(err.status, 405)
    t.assert_equals(err.message, 'сюда так нельзя')
    t.assert_equals(g.errors.response(err).headers.allow, 'GET')
end

g.test_our_own_failure_passes_through_untouched = function()
    local err = missing(7)

    t.assert_equals(g.errors.of(err), err)
end

g.test_a_foreign_word_on_the_place_of_a_code_never_becomes_a_lookup = function()
    -- Из-за догадки по виду строки чужое `timeout` — латиница, без
    -- пробелов — уходило искать себя в каталоге и роняло узел: 500 там,
    -- где хватило бы внятного слова.
    helper.refuses(
        function()
            g.errors.wrap('сервер молчит', 'timeout')
        end,
        'отказ timeout не объявлен: объявите его define либо накройте причину словом через explain'
    )

    helper.refuses(function()
        g.errors.wrap('сервер молчит', 'клиента не удалось показать')
    end, 'накройте причину словом через explain')

    -- Причина названа в тексте исключения: до `of` дело не дошло, записи
    -- о происшествии нет, и без неё она пропала бы бесследно.
    helper.refuses(function()
        g.errors.wrap('к базе не достучались: postgres://root:hunter2@db', 'timeout')
    end, 'причина: к базе не достучались: postgres://root:[скрыто]@db')

    -- А слово для человека тем же вызовом проходит наружу целиком.
    t.assert_equals(g.errors.explain('сервер молчит', 'timeout').message, 'timeout')
end

g.test_a_table_cause_is_named_by_its_fields_when_the_code_is_unknown = function()
    -- Записи о происшествии здесь не будет, и адрес таблицы в тексте
    -- исключения оставил бы от причины одно `table: 0x…`.
    helper.refuses(function()
        g.errors.wrap({ code = 'storage.down' }, 'timeout')
    end, 'причина: {"code":"storage.down"})')

    helper.refuses(function()
        g.errors.wrap({ password = 'hunter2' }, 'timeout')
    end, 'причина: {"password":"[скрыто]"})')
end

g.test_wrapping_by_code_puts_a_new_kind_on_top_and_keeps_the_cause = function()
    g.errors.define('mail.not_sent', { status = 502, message = 'Письмо не ушло' })

    local err = g.errors.wrap('сервер молчит', 'mail.not_sent')

    t.assert_equals(g.errors.code_of(err), 'mail.not_sent')
    t.assert_equals(err.status, 502)
    t.assert_equals(
        tostring(err),
        table.concat({
            'Письмо не ушло',
            'Внутренняя ошибка. Назовите происшествие '
                .. helper.INCIDENT
                .. ' тому, кто будет разбираться.',
            'сервер молчит',
        }, ': ')
    )
    -- Опознаватель наследуется: запись о происшествии уже написана,
    -- и второй номер увёл бы человека туда, где ничего нет.
    t.assert_equals(g.errors.incident_of(err), helper.INCIDENT)
end

g.test_explaining_changes_only_what_is_said = function()
    -- Случилось всё то же самое, просто сказать об этом надо иначе:
    -- род отказа, статус и опознаватель остаются от причины.
    local err = g.errors.explain(missing(7), 'клиента не удалось показать')

    t.assert_equals(g.errors.code_of(err), 'customer.not_found')
    t.assert_equals(err.status, 404)
    t.assert_equals(err.title, 'Клиента №{id} нет')
    t.assert_equals(err.message, 'клиента не удалось показать')
    t.assert_equals(tostring(err), 'клиента не удалось показать: Клиента №7 нет')
end

g.test_a_human_word_over_a_breakage_still_goes_out = function()
    -- Это слово писал разработчик для человека, а не чужая библиотека:
    -- показать его можно, и оно куда полезнее общей фразы.
    local err = g.errors.explain('сервер молчит', 'письмо не ушло')
    local body = g.errors.render(err)

    t.assert_equals(body.detail, 'письмо не ушло')
    t.assert_equals(body.status, 500)
    t.assert_equals(body.incident, helper.INCIDENT)
    t.assert_equals(g.errors.expected(err), false)
end

g.test_a_word_that_is_not_a_string_is_refused_the_same_as_a_wrong_code = function()
    -- `explain(err, nil)` показал бы человеку строку «nil», а таблица
    -- доехала бы до клиента целиком. Это промах кода, а не отказ клиенту.
    helper.refuses(function()
        g.errors.explain('сервер молчит', nil)
    end, 'слово для человека пишется строкой, а не nil')

    helper.refuses(function()
        g.errors.explain('сервер молчит', { 'письмо не ушло' })
    end, 'слово для человека пишется строкой, а не table')
end

g.test_secrets_in_an_explaining_word_are_cut_out = function()
    local err = g.errors.explain('сервер молчит', 'не вошли по ключу /enter?token=abc123')

    t.assert_equals(err.message, 'не вошли по ключу /enter?token=[скрыто]')
end

g.test_the_answer_carries_the_status_the_media_type_and_the_body = function()
    local answer = g.errors.response(missing(7))

    t.assert_equals(answer.status, 404)
    t.assert_equals(answer.headers, { ['content-type'] = 'application/problem+json' })
    -- Тело строкой, а не таблицей: ответ уходит в `http.server` как есть,
    -- а таблицу тот напечатает клиенту как «table: 0x...».
    t.assert_equals(type(answer.body), 'string')
    t.assert_equals(helper.body(answer), {
        type = 'urn:tnt-error:customer.not_found',
        title = 'Клиента №{id} нет',
        detail = 'Клиента №7 нет',
        status = 404,
        code = 'customer.not_found',
    })
end

g.test_rendering_says_the_status_beside_the_body = function()
    -- Простой вид статуса в теле не несёт, а ответу он нужен всегда.
    local body, status = g.errors.render(missing(7))

    t.assert_equals(status, 404)
    t.assert_equals(body.status, 404)
end

g.test_another_view_is_asked_for_by_settings = function()
    g.errors.configure({ view = 'simple' })

    local answer = g.errors.response(missing(7))

    t.assert_equals(answer.headers, { ['content-type'] = 'application/json' })
    t.assert_equals(helper.body(answer), {
        error = 'customer.not_found',
        message = 'Клиента №7 нет',
    })
end

g.test_settings_change_the_uri_of_the_kind_and_of_the_incident = function()
    g.errors.configure({
        type_base = 'https://docs.example/errors/',
        instance_base = 'https://ops.example/incidents/',
    })

    local shown = g.errors.render(missing(7))

    t.assert_equals(shown.type, 'https://docs.example/errors/customer.not_found')
    t.assert_equals(
        g.errors.render(g.errors.of('сервер молчит')).instance,
        'https://ops.example/incidents/' .. helper.INCIDENT
    )
end

g.test_settings_do_not_take_the_declared_failures_away = function()
    -- Отказы объявляются пакетами при загрузке, то есть до всякой
    -- настройки, и новый каталог потерял бы их все.
    g.errors.configure({ view = 'simple' })

    t.assert_equals(g.errors.defined('customer.not_found').status, 404)
end

g.test_a_setting_that_does_not_hold_together_is_refused_at_startup = function()
    helper.refuses(
        function()
            g.errors.configure({ view = 'красиво' })
        end,
        "вид ответа должен быть одним из: 'problem', 'simple' либо своей функцией, а не 'красиво'"
    )

    helper.refuses(function()
        g.errors.registry({ type_base = 42 })
    end, 'начало URI рода отказа должно быть строкой')

    helper.refuses(function()
        g.errors.registry({ content_type = '' })
    end, 'подпись ответа должна быть строкой длиной не меньше 1 знака')
end

g.test_a_separate_catalogue_shares_nothing_with_the_common_one = function()
    local own = g.errors.registry({ view = 'simple' })

    own:define('customer.not_found', { status = 410, message = 'Ушёл' })

    -- Отдельный каталог знает свой статус, а не статус общего.
    t.assert_equals(own:new('customer.not_found').status, 410)
    t.assert_equals(g.errors.defined('customer.not_found').status, 404)
    t.assert_equals(helper.body(own:response(own:new('customer.not_found'))).error, 'customer.not_found')
end

g.test_status_tells_what_is_set_up_and_how_many_codes_are_known = function()
    t.assert_equals(g.errors.status(), {
        view = 'problem',
        content_type = 'application/problem+json',
        type_base = 'urn:tnt-error:',
        instance_base = 'urn:tnt-incident:',
        page = 'builtin',
        debug = false,
        translate = false,
        codes = 2,
    })
end

g.test_a_view_of_ones_own_builds_the_body_the_panel_expects = function()
    -- Готовая панель ждёт ровно то тело, которое умеет разбирать,
    -- и переучиваться ей нечем: она собрана из чужих кусков.
    local seen = {}

    g.errors.configure({
        view = function(err, settings)
            seen.type_base = settings.type_base

            return { error = { status = err.status, message = err.message } }
        end,
    })

    local answer = g.errors.response(missing(7))

    t.assert_equals(answer.status, 404)
    -- Тело собрано таблицей, и уезжает оно обычным JSON.
    t.assert_equals(answer.headers, { ['content-type'] = 'application/json' })
    t.assert_equals(helper.body(answer), { error = { status = 404, message = 'Клиента №7 нет' } })
    -- Настройки доходят до своей функции целиком: по ним она соберёт
    -- и URI рода отказа, если он ей нужен.
    t.assert_equals(seen.type_base, 'urn:tnt-error:')
    t.assert_equals(g.errors.status().view, 'custom')
end

g.test_the_signature_of_the_answer_is_told_apart_from_the_view = function()
    g.errors.configure({
        view = function(err)
            return { message = err.message }
        end,
        content_type = 'application/vnd.panel+json',
    })

    t.assert_equals(g.errors.response(missing(7)).headers, { ['content-type'] = 'application/vnd.panel+json' })
    t.assert_equals(g.errors.status().content_type, 'application/vnd.panel+json')

    -- И у готового вида подпись перебивается ровно так же.
    g.errors.configure({ view = 'simple', content_type = 'text/plain' })

    t.assert_equals(g.errors.status(), {
        view = 'simple',
        content_type = 'text/plain',
        type_base = 'urn:tnt-error:',
        instance_base = 'urn:tnt-incident:',
        page = 'builtin',
        debug = false,
        translate = false,
        codes = 2,
    })
end

g.test_the_word_at_five_hundred_is_the_applications_to_choose = function()
    -- `define` занятый код не отдаёт, и без переопределения приложению
    -- нечем сказать своё слово там, где его увидят чаще прочих.
    g.errors.redefine(g.errors.INTERNAL, {
        status = 503,
        title = 'Не сейчас',
        message = 'Панель прилегла. Назовите {incident} дежурному.',
    })

    local err = g.errors.of('сервер молчит')
    local body, status = g.errors.render(err)

    t.assert_equals(status, 503)
    t.assert_equals(
        body.detail,
        'Панель прилегла. Назовите ' .. helper.INCIDENT .. ' дежурному.'
    )
    t.assert_equals(body.title, 'Не сейчас')
    -- Опознаватель остался и сам по себе: по нему поломку и найдут.
    t.assert_equals(body.incident, helper.INCIDENT)
    t.assert_equals(helper.logged(helper.INCIDENT), true)
end

g.test_the_replaced_word_at_five_hundred_still_names_the_incident = function()
    -- Опознаватель и есть весь ответ при 500: остальное в нём — общая
    -- фраза, одинаковая для всех поломок.
    helper.refuses(function()
        g.errors.redefine(g.errors.INTERNAL, { status = 500, message = 'Что-то пошло не так' })
    end, 'слово внутренней поломки обязано называть {incident}')

    -- Слово не той породы разбирает проверка объявления: ей об этом
    -- сказать точнее.
    helper.refuses(function()
        g.errors.redefine(g.errors.INTERNAL, { status = 500, message = 42 })
    end, 'строка для человека должна быть строкой')

    t.assert_str_contains(g.errors.defined(g.errors.INTERNAL).message, '{incident}')

    -- А назван он может быть где угодно, хоть первым словом.
    g.errors.redefine(g.errors.INTERNAL, { status = 500, message = '{incident} — назовите его' })

    t.assert_equals(g.errors.of('сервер молчит').message, helper.INCIDENT .. ' — назовите его')
end

g.test_the_kind_of_the_internal_breakage_is_replaced_along_with_its_word = function()
    -- Объявление принимает `type`, и `internal` обязан его передавать
    -- наравне со статусом и словом: иначе замена проходит проверку,
    -- ложится в каталог и не делает ничего — в ответе остаётся прежний URI.
    g.errors.redefine(g.errors.INTERNAL, {
        status = 500,
        message = 'Внутренняя ошибка. Назовите {incident}.',
        type = 'https://ops.example/errors/500',
    })

    t.assert_equals(g.errors.render(g.errors.of('сервер молчит')).type, 'https://ops.example/errors/500')
end

g.test_the_word_of_an_ordinary_failure_is_replaced_without_ceremony = function()
    -- Требование про опознаватель — только к внутренней поломке:
    -- у ожидаемого отказа происшествия нет вовсе.
    g.errors.redefine('customer.not_found', { status = 410, message = 'Клиент №{id} ушёл' })

    t.assert_equals(g.errors.new('customer.not_found', { id = 7 }).message, 'Клиент №7 ушёл')
    t.assert_equals(g.errors.new('customer.not_found', { id = 7 }).status, 410)
end
