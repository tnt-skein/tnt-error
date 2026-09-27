--- Проверки перевода: слово отказа на языке запроса, заголовки ответа
--- и то, чего перевод не трогает.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.error.translation')

--- Английские слова по кодам, как их отдал бы переводчик приложения.
local ENGLISH = {
    ['customer.not_found'] = 'Customer {id} not found',
    internal = 'Something broke. Tell {incident} to whoever looks into it.',
}

--- Запрос, язык которого выбрал слой языка.
---@param locale string|nil
---@param accept string|nil Заголовок `Accept`
---@return table
local function asking(locale, accept)
    return { method = 'GET', path = '/customers/7', headers = { accept = accept }, locale = locale }
end

--- Перевод по словарю: слово по коду с подстановками и язык запроса.
---
--- Помнит, кого и о чём спросили: перевод обязан получить отказ целиком
--- и тот самый запрос.
---@param asked table[] Куда складывать вопросы
---@return fun(err: TntError, request: any): string|nil, string|nil
local function dictionary(asked)
    return function(err, request)
        table.insert(asked, { err = err, request = request })

        if request == nil or request.locale ~= 'en' or ENGLISH[err.code] == nil then
            return nil
        end

        local params = { incident = err.incident }

        for name, value in pairs(err.params) do
            params[name] = value
        end

        return (ENGLISH[err.code]:gsub('{(%w+)}', params)), 'en'
    end
end

--- Каталог с переводом и объявленным отказом клиента.
---@param translate function
---@param opts table|nil Прочие настройки
---@return table catalog
local function translated(translate, opts)
    local settings = { translate = translate }

    for name, value in pairs(opts or {}) do
        settings[name] = value
    end

    local catalog = g.errors.registry(settings)

    catalog:define('customer.not_found', { status = 404, message = 'Клиента №{id} нет' })

    return catalog
end

g.test_the_word_speaks_the_language_of_the_request = function()
    local asked = {}
    local catalog = translated(dictionary(asked))
    local err = catalog:new('customer.not_found', { id = 7 })
    local request = asking('en')
    local answer = catalog:response(err, request)

    t.assert_equals(answer.status, 404)
    t.assert_equals(answer.headers, {
        ['content-type'] = 'application/problem+json',
        ['content-language'] = 'en',
        vary = 'Accept-Language',
    })
    -- Переводится слово — то, что сказано об этом случае; имя рода отказа
    -- остаётся, каким его объявили.
    t.assert_equals(helper.body(answer), {
        type = 'urn:tnt-error:customer.not_found',
        title = 'Клиента №{id} нет',
        status = 404,
        detail = 'Customer 7 not found',
        code = 'customer.not_found',
    })

    -- Перевод получил отказ целиком и тот самый запрос.
    t.assert_equals(#asked, 1)
    t.assert_is(asked[1].err, err)
    t.assert_is(asked[1].request, request)

    -- Сам отказ не тронут: его пишут в журнал и рисуют другому запросу
    -- на другом языке.
    t.assert_equals(err.message, 'Клиента №7 нет')
    t.assert_equals(helper.logged('слово отказа не переведено'), false)
end

g.test_a_request_without_a_translation_gets_the_word_of_the_catalogue = function()
    local catalog = translated(dictionary({}))
    local answer = catalog:response(catalog:new('customer.not_found', { id = 7 }), asking('ru'))

    t.assert_equals(helper.body(answer).detail, 'Клиента №7 нет')
    -- Слово каталога написано на своём языке, и чужой язык ему не ставят;
    -- а `Vary` нужен и ему: на другом языке слово нашлось бы.
    t.assert_equals(answer.headers, { ['content-type'] = 'application/problem+json', vary = 'Accept-Language' })
    t.assert_equals(helper.logged('слово отказа не переведено'), false)

    -- Без запроса переводу искать язык не в чем, и ответ прежний.
    t.assert_equals(
        helper.body(catalog:response(catalog:new('customer.not_found', { id = 7 }))).detail,
        'Клиента №7 нет'
    )
end

g.test_without_a_translation_nothing_changes = function()
    local catalog = g.errors.registry({ view = 'simple' })

    catalog:define('customer.not_found', { status = 404, message = 'Клиента №{id} нет' })

    local answer = catalog:response(catalog:new('customer.not_found', { id = 7 }), asking('en'))

    t.assert_equals(answer.headers, { ['content-type'] = 'application/json' })
    t.assert_equals(helper.body(answer), { error = 'customer.not_found', message = 'Клиента №7 нет' })
    t.assert_equals(catalog:status().translate, false)
    t.assert_equals(helper.logged('слово отказа не переведено'), false)
end

g.test_the_body_and_the_page_carry_the_translated_word = function()
    local catalog = translated(dictionary({}), { view = 'simple' })
    local err = catalog:new('customer.not_found', { id = 7 })

    t.assert_equals(catalog:status().translate, true)

    local body, status = catalog:render(err, asking('en'))

    t.assert_equals(status, 404)
    t.assert_equals(body, { error = 'customer.not_found', message = 'Customer 7 not found' })

    local page = catalog:response(err, asking('en', 'text/html'))

    t.assert_equals(page.headers['content-type'], 'text/html; charset=utf-8')
    t.assert_equals(page.headers['content-language'], 'en')
    t.assert_str_contains(page.body, '<p>Customer 7 not found</p>')
end

g.test_the_common_catalogue_passes_the_request_to_the_translation = function()
    helper.declare_customer(g.errors)
    g.errors.configure({ view = 'simple', translate = dictionary({}) })

    local err = g.errors.new('customer.not_found', { id = 7 })

    t.assert_equals(g.errors.render(err, asking('en')).message, 'Customer 7 not found')
    t.assert_equals(helper.body(g.errors.response(err, asking('en'))).message, 'Customer 7 not found')
    t.assert_equals(g.errors.status().translate, true)
end

g.test_the_word_of_the_translation_is_still_a_failure_of_the_catalogue = function()
    local seen = {}
    local catalog = translated(dictionary({}), {
        view = function(err)
            seen.err = err

            return { message = err.message }
        end,
    })

    catalog:response(catalog:new('customer.not_found', { id = 7 }), asking('en'))

    -- Своя функция вида получает отказ, а не просто таблицу: код,
    -- подстановки и цепочка у него те же.
    t.assert_equals(g.errors.code_of(seen.err), 'customer.not_found')
    t.assert_equals(seen.err.params, { id = 7 })
    t.assert_equals(tostring(seen.err), 'Customer 7 not found')
end

g.test_a_word_of_ones_own_is_not_translated = function()
    local asked = {}
    local catalog = translated(dictionary(asked))
    local err =
        catalog:explain(catalog:new('customer.not_found', { id = 7 }), 'клиента №7 увели в архив')
    local answer = catalog:response(err, asking('en'))

    -- Слово `explain` разработчик написал для этого случая, и строка
    -- по коду сказала бы меньше.
    t.assert_equals(helper.body(answer).detail, 'клиента №7 увели в архив')
    t.assert_equals(answer.headers['content-language'], nil)
    t.assert_equals(answer.headers.vary, 'Accept-Language')
    t.assert_equals(asked, {})

    -- А объявленный отказ поверх своего слова переводится по своему коду.
    local wrapped = catalog:wrap(err, 'customer.not_found', { id = 8 })

    t.assert_equals(helper.body(catalog:response(wrapped, asking('en'))).detail, 'Customer 8 not found')
end

g.test_the_word_at_five_hundred_keeps_the_incident = function()
    local catalog = translated(dictionary({}), { view = 'simple' })
    local _, err = catalog:guard(error, 'соединение с базой порвано')
    local answer = catalog:response(err, asking('en'))

    t.assert_equals(helper.body(answer), {
        error = 'internal',
        message = 'Something broke. Tell 0000-0000 to whoever looks into it.',
        incident = helper.INCIDENT,
    })
    t.assert_equals(answer.headers['content-language'], 'en')
end

g.test_a_word_at_five_hundred_without_the_incident_is_refused = function()
    local catalog = translated(function()
        return 'Something broke.', 'en'
    end, { view = 'simple' })
    local _, err = catalog:guard(error, 'соединение с базой порвано')
    local answer = catalog:response(err, asking('en'))

    -- Номер — весь ответ при 500: слово без него человеку не годится.
    t.assert_equals(helper.body(answer).message, err.message)
    t.assert_str_contains(err.message, helper.INCIDENT)
    t.assert_equals(answer.headers['content-language'], nil)
    t.assert_equals(helper.fields('слово отказа не переведено'), {
        code = 'internal',
        reason = 'слово внутренней поломки не называет происшествие 0000-0000',
    })
end

g.test_only_the_word_of_the_breakdown_itself_must_name_the_incident = function()
    local catalog = translated(function(err)
        return ('%s: no incident here'):format(err.code), 'en'
    end, { view = 'simple' })
    local _, broken = catalog:guard(error, 'соединение с базой порвано')

    -- Объявленный отказ поверх поломки номер наследует, но своё слово
    -- называть его не обязан: номер уходит в теле рядом со словом.
    local answer = catalog:response(catalog:wrap(broken, 'customer.not_found', { id = 7 }), asking('en'))

    t.assert_equals(helper.body(answer), {
        error = 'customer.not_found',
        message = 'customer.not_found: no incident here',
        incident = helper.INCIDENT,
    })

    -- Чужой отказ с кодом внутренней поломки, но без номера — тоже.
    local adopted = catalog:response({ status = 500, code = 'internal', message = 'сломалось' }, asking('en'))

    t.assert_equals(helper.body(adopted).message, 'internal: no incident here')
end

g.test_a_translation_that_broke_leaves_the_word_of_the_catalogue = function()
    local cases = {
        {
            translate = function()
                error('строки перевода не прочитаны', 0)
            end,
            reason = 'строки перевода не прочитаны',
        },
        {
            translate = function()
                return 42, 'en'
            end,
            reason = 'перевод отдал number, а не строку',
        },
        {
            translate = function()
                return { 'Customer 7 not found' }, 'en'
            end,
            reason = 'перевод отдал table, а не строку',
        },
    }

    for _, case in ipairs(cases) do
        local catalog = translated(case.translate)
        local answer = catalog:response(catalog:new('customer.not_found', { id = 7 }), asking('en'))

        t.assert_equals(helper.body(answer).detail, 'Клиента №7 нет', case.reason)
        t.assert_equals(answer.headers['content-language'], nil, case.reason)
        t.assert_equals(helper.fields('слово отказа не переведено'), {
            code = 'customer.not_found',
            reason = case.reason,
        })

        helper.forget()
    end
end

g.test_a_language_that_is_not_a_string_is_not_named = function()
    for _, language in ipairs({ false, 42, { 'en' } }) do
        local catalog = translated(function()
            return 'Customer not found', language
        end)
        local answer = catalog:response(catalog:new('customer.not_found', { id = 7 }), asking('en'))

        t.assert_equals(helper.body(answer).detail, 'Customer not found')
        t.assert_equals(answer.headers['content-language'], nil)
        t.assert_equals(answer.headers.vary, 'Accept-Language')
    end
end

g.test_secrets_do_not_leave_with_the_translated_word = function()
    local catalog = translated(function()
        return 'Could not reach postgres://root:hunter2@db/main', 'en'
    end)
    local answer = catalog:response(catalog:new('customer.not_found', { id = 7 }), asking('en'))

    t.assert_equals(helper.body(answer).detail, 'Could not reach postgres://root:[скрыто]@db/main')
end

g.test_the_headers_of_the_refusal_are_kept_and_joined = function()
    local catalog = translated(dictionary({}))
    local cases = {
        { vary = 'Cookie', expected = 'Cookie, Accept-Language' },
        { vary = 'accept-language', expected = 'accept-language' },
        { vary = 'Origin , Accept-Language ', expected = 'Origin , Accept-Language ' },
        { vary = 'Accept-Language-Extra', expected = 'Accept-Language-Extra, Accept-Language' },
        { vary = 'X-Accept-Language', expected = 'X-Accept-Language, Accept-Language' },
        { vary = '*', expected = '*' },
        { vary = 'Origin, *', expected = 'Origin, *' },
        { language = 'ru', expected = 'Accept-Language' },
    }

    for _, case in ipairs(cases) do
        local refusal = {
            status = 404,
            code = 'customer.not_found',
            message = 'Клиента №7 нет',
            headers = { vary = case.vary, ['content-language'] = case.language },
        }
        local answer = catalog:response(refusal, asking('en'))

        t.assert_equals(answer.headers.vary, case.expected, case.vary)
        -- Язык, названный самим отказом, остаётся: ему виднее, на каком
        -- языке он сказан.
        t.assert_equals(answer.headers['content-language'], case.language or 'en', case.vary)
        -- Заголовки самого отказа не тронуты: их ставят в копию.
        t.assert_equals(refusal.headers.vary, case.vary)
    end

    local odd = { 'Accept-Language' }
    local answer = catalog:response({ status = 404, headers = { vary = odd } }, asking('en'))

    t.assert_is(answer.headers.vary, odd)
end

g.test_the_translation_must_be_a_function = function()
    for _, wrong in ipairs({ 'en', true, { en = {} } }) do
        helper.refuses(
            function()
                g.errors.registry({ translate = wrong })
            end,
            'перевод слова отказа должен быть функцией от отказа и запроса'
        )
    end
end
