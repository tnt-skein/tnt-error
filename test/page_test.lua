--- Проверки страницы отказа: что видит человек в браузере и что —
--- разработчик в режиме разбора.

local t = require('luatest')

local context = require('tnt.context')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.error.page')

--- Тайна, которой не место ни на одной странице.
local SECRET = 'hunter2'

--- Запрос браузера: заголовки и поля строки запроса с тайнами.
local function browsing()
    return {
        method = 'GET',
        path = '/customers/7',
        query = { token = SECRET, page = '2' },
        headers = {
            accept = 'text/html',
            authorization = 'Bearer ' .. SECRET,
            host = 'example.org',
        },
    }
end

--- Каталог со своими настройками и объявленным отказом клиента.
---@param opts table|nil
---@return table catalog
local function catalog_of(opts)
    local catalog = g.errors.registry(opts)

    catalog:define('customer.not_found', { status = 404, message = 'Клиента №{id} нет' })

    return catalog
end

--- Страница ответа на промах по адресу.
---@param opts table|nil Настройки каталога
---@param params table|nil Подстановки в слово отказа
---@return table response
local function missing(opts, params)
    local catalog = catalog_of(opts)

    return catalog:response(catalog:new('customer.not_found', params or { id = 7 }), browsing())
end

--- Ответ на поломку внутри обработчика.
---@param opts table|nil Настройки каталога
---@param request any Запрос, из-за которого отказали
---@return table response
local function broken(opts, request)
    local catalog = catalog_of(opts)
    local _, err = catalog:guard(function()
        ---@type any
        local nothing = nil

        return nothing.field
    end)

    return catalog:response(err, request)
end

g.test_the_browser_gets_a_page_and_the_script_the_same_body_as_before = function()
    local page = missing()

    t.assert_equals(page.status, 404)
    t.assert_equals(page.headers['content-type'], 'text/html; charset=utf-8')
    t.assert_str_contains(page.body, '<title>404 — Страницы нет</title>')
    t.assert_str_contains(page.body, '<h1>Страницы нет</h1>')
    t.assert_str_contains(page.body, '<p>Клиента №7 нет</p>')

    -- Сценарию тот же отказ уходит прежним телом.
    local catalog = catalog_of()
    local body = catalog:response(catalog:new('customer.not_found', { id = 7 }), { headers = {} })

    t.assert_equals(body.headers['content-type'], 'application/problem+json')
    t.assert_equals(helper.body(body).detail, 'Клиента №7 нет')
end

g.test_a_word_with_markup_in_it_does_not_become_markup = function()
    -- Подстановка приходит из адреса запроса, и страница экранирует её:
    -- склейка строк забыла бы про это ровно здесь.
    local page = missing(nil, { id = '<script>alert(1)</script>' })

    t.assert_str_contains(page.body, '&lt;script&gt;alert(1)&lt;/script&gt;')
    t.assert_equals(page.body:find('<script>', 1, true), nil)
end

g.test_every_status_of_the_boundary_has_its_own_title = function()
    -- Заголовок человек читает раньше слова, и на каждый код ответа,
    -- которым отвечает граница HTTP, он свой.
    local page = helper.part('tnt.error.page')
    local settings = g.errors.registry(nil).settings

    for _, case in ipairs({
        { status = 400, title = 'Запрос не понят' },
        { status = 401, title = 'Нужно войти' },
        { status = 403, title = 'Сюда нельзя' },
        { status = 404, title = 'Страницы нет' },
        { status = 405, title = 'Так сюда нельзя' },
        { status = 408, title = 'Запрос не пришёл вовремя' },
        { status = 413, title = 'Запрос слишком велик' },
        { status = 422, title = 'Данные не подошли' },
        { status = 429, title = 'Слишком часто' },
        { status = 500, title = 'Что-то сломалось' },
        { status = 502, title = 'Соседняя служба молчит' },
        { status = 503, title = 'Сейчас не работаем' },
        { status = 504, title = 'Ответа не дождались' },
    }) do
        ---@type any
        local err = { status = case.status, message = 'слово' }

        t.assert_equals(page.view(err, nil, settings).title, case.title, case.status)
    end
end

g.test_an_unnamed_status_gets_the_common_title = function()
    local catalog = g.errors.registry(nil)

    catalog:define('teapot', { status = 418, message = 'Я чайник' })

    local page = catalog:response(catalog:new('teapot'), browsing())

    t.assert_str_contains(page.body, '<h1>Не получилось</h1>')
    t.assert_str_contains(page.body, '<p>Я чайник</p>')
end

g.test_the_page_names_the_numbers_that_lead_to_the_journal = function()
    -- Опознаватель запроса берётся из контекста файбера — оттуда же,
    -- откуда его берёт журнал: номер на странице заведомо тот, по которому
    -- запись найдут.
    local page = context.run({ [context.REQUEST_ID] = '01JB5TESTREQUEST' }, broken, nil, browsing())

    t.assert_equals(page.status, 500)
    t.assert_str_contains(page.body, 'Происшествие <code>' .. helper.INCIDENT .. '</code>')
    t.assert_str_contains(page.body, 'Запрос <code>01JB5TESTREQUEST</code>')
    t.assert_equals(helper.logged(helper.INCIDENT), true)

    -- Без области контекста номера запроса нет, а страница рисуется.
    local alone = broken(nil, browsing())

    t.assert_str_contains(alone.body, 'Происшествие <code>' .. helper.INCIDENT .. '</code>')
    t.assert_equals(alone.body:find('Запрос <code>', 1, true), nil)
end

g.test_in_production_the_page_says_nothing_about_the_inside = function()
    local page = broken(nil, browsing())

    t.assert_equals(page.body:find('Стек', 1, true), nil)
    t.assert_equals(page.body:find('Где сломалось', 1, true), nil)
    t.assert_equals(page.body:find('Заголовки', 1, true), nil)
    t.assert_equals(page.body:find('attempt to index', 1, true), nil)
end

g.test_the_breakdown_page_shows_where_it_broke_and_with_what = function()
    local page = broken({ debug = true }, browsing())

    t.assert_str_contains(page.body, '<h2>Где сломалось</h2>')
    t.assert_str_contains(page.body, 'page_test.lua:')
    t.assert_str_contains(page.body, 'attempt to index')
    t.assert_str_contains(page.body, '<h2>Стек</h2>')
    t.assert_str_contains(page.body, 'stack traceback:')

    -- С чем пришли: способ, путь, поля строки запроса и заголовки.
    t.assert_str_contains(page.body, '<code>GET /customers/7</code>')
    t.assert_str_contains(page.body, '<tr><th>page</th><td>2</td></tr>')
    t.assert_str_contains(page.body, '<tr><th>host</th><td>example.org</td></tr>')

    -- Заголовки идут по алфавиту: порядок ключей в Lua не задан, и без
    -- сортировки страница перекладывала бы их при каждом обновлении.
    local accept_at = page.body:find('<th>accept</th>', 1, true)
    local host_at = page.body:find('<th>host</th>', 1, true)

    t.assert_not_equals(accept_at, nil)
    t.assert_lt(accept_at, host_at)

    -- И ни одной тайны: правило то же, каким они вырезаются из журнала.
    t.assert_str_contains(page.body, '<tr><th>token</th><td>[скрыто]</td></tr>')
    t.assert_str_contains(page.body, '<tr><th>authorization</th><td>[скрыто]</td></tr>')
    t.assert_equals(page.body:find(SECRET, 1, true), nil)
end

g.test_the_breakdown_page_is_drawn_without_a_request_and_without_a_stack = function()
    local page = helper.part('tnt.error.page')
    local catalog = catalog_of({ debug = true })

    -- Поломка, пришедшая парой `nil, err`: стека у неё нет, и места
    -- в коде тоже — страница об этом молчит, а цепочку показывает.
    local drawn = page.of(catalog:internal('к базе не достучались'), nil, catalog.settings)

    t.assert_equals(drawn:find('Где сломалось', 1, true), nil)
    t.assert_equals(drawn:find('<h2>Стек</h2>', 1, true), nil)
    t.assert_str_contains(drawn, '<li>к базе не достучались</li>')
    t.assert_str_contains(drawn, '<h2>Заголовки</h2>')

    -- Стек без единого кадра на Lua: место назвать нечем, а сам стек
    -- на странице есть.
    local bare =
        page.of(catalog:internal('оно', "stack traceback:\n\t[C]: in function 'error'"), nil, catalog.settings)

    t.assert_equals(bare:find('Где сломалось', 1, true), nil)
    t.assert_str_contains(bare, '[C]: in function &#39;error&#39;')
end

--- Место в коде, которое страница разбора назвала этой поломке.
---@param cause any Из-за чего сломалось
---@param traceback string|nil Стек на месте поломки
---@return string|nil
local function placed(cause, traceback)
    local page = helper.part('tnt.error.page')
    local catalog = catalog_of({ debug = true })
    local drawn = page.of(catalog:internal(cause, traceback), nil, catalog.settings)

    return drawn:match('<h2>Где сломалось</h2>%s*<p><code>(.-)</code></p>')
end

g.test_the_place_is_the_first_frame_of_the_stack_on_lua = function()
    -- Верхний кадр обычно `[C]: in function 'error'`: им поломка сказана,
    -- но не объяснена, и человеку нужен первый кадр на Lua — целиком,
    -- вместе с тем, что в нём делали.
    t.assert_equals(
        placed(
            'упал',
            "\nstack traceback:\n\t[C]: in function 'error'"
                .. '\n\tsrc/app/service.lua:7: in function <src/app/service.lua:5>'
        ),
        'src/app/service.lua:7: in function &lt;src/app/service.lua:5&gt;'
    )

    -- Кадр узнаётся по пути и номеру строки, а не по двоеточиям: ни кадра
    -- без пути, ни кадра без номера страница местом не считает.
    t.assert_equals(placed('упал', '\n\t:12: кадр без пути'), nil)
    t.assert_equals(placed('упал', '\n\tsrc/app.lua:: кадр без номера'), nil)

    -- Отступ перед кадром необязателен: стек чужой библиотеки пишут
    -- и без него.
    t.assert_equals(
        placed('упал', '\nsrc/app.lua:12: без отступа'),
        'src/app.lua:12: без отступа'
    )
    -- И хвоста за местом может не быть вовсе.
    t.assert_equals(placed('упал', '\n\tsrc/app.lua:12:'), 'src/app.lua:12:')
end

g.test_the_place_is_named_even_when_the_stack_is_lost = function()
    -- Бросок, пойманный чужим `pcall` и отданный парой строкой, приходит
    -- уже без стека. Место в строке остаётся — его пишет сама Lua, —
    -- и страница называет его.
    t.assert_equals(
        placed('не сохранилось: src/app/handlers.lua:12: нет такого поля'),
        'src/app/handlers.lua:12'
    )

    -- И здесь место узнаётся по пути и номеру строки: ни одного, ни
    -- другого мало.
    t.assert_equals(placed(':12: слово без пути'), nil)
    t.assert_equals(placed('src/app.lua:: слово без номера'), nil)
end

g.test_the_place_is_looked_for_from_the_bottom_of_the_chain_up = function()
    -- Нижний слой цепочки — та самая поломка, верхние уже накрыты словом
    -- разработчика. Но место бывает и в верхнем: тогда находится оно,
    -- и обойти надо всю цепочку до самого верха.
    local page = helper.part('tnt.error.page')
    local catalog = catalog_of({ debug = true })

    catalog:redefine(helper.part('tnt.error.catalog').INTERNAL, {
        status = 500,
        title = 'Ой',
        message = 'сломалось в src/app/boot.lua:9: происшествие {incident}',
    })

    local drawn = page.of(catalog:internal('причина без места'), nil, catalog.settings)

    t.assert_str_contains(drawn, '<code>src/app/boot.lua:9</code>')
end

g.test_the_breakdown_page_is_for_a_breakage_and_for_nothing_else = function()
    -- Ожидаемый отказ разбирать нечего: он весь сказан словом, и человеку
    -- в разработке полезнее та же страница, что и в бою.
    local page = missing({ debug = true })

    t.assert_equals(page.body:find('Стек', 1, true), nil)
    t.assert_str_contains(page.body, '<h1>Страницы нет</h1>')
end

g.test_the_application_draws_the_page_itself_when_it_has_one = function()
    local seen = {}
    local page = missing({
        page = function(shown)
            seen = shown

            return ('<p>%s: %s</p>'):format(shown.status, shown.message)
        end,
    })

    t.assert_equals(page.body, '<p>404: Клиента №7 нет</p>')
    t.assert_equals(page.headers['content-type'], 'text/html; charset=utf-8')

    -- Своя страница получает те же данные, что и встроенная, — но без
    -- подробностей поломки: их рисует только страница разбора.
    t.assert_equals(seen.title, 'Страницы нет')
    t.assert_equals(seen.details, nil)
end

g.test_the_breakdown_page_beats_the_page_of_the_application = function()
    -- В разработке стек нужнее рамки сайта, и своей страницы поломки
    -- у приложения всё равно нет — подробностей ей не дают.
    local called = false
    local page = broken({
        debug = true,
        page = function()
            called = true

            return '<p>наша</p>'
        end,
    }, browsing())

    t.assert_equals(called, false)
    t.assert_str_contains(page.body, '<h2>Стек</h2>')
end

g.test_a_page_that_did_not_draw_does_not_leave_the_man_without_an_answer = function()
    -- Страницы на этот код у приложения нет: рисует встроенная, и молча —
    -- это обычное состояние, а не беда.
    local absent = missing({
        page = function()
            return nil
        end,
    })

    t.assert_str_contains(absent.body, '<h1>Страницы нет</h1>')
    t.assert_equals(
        helper.logged('страница отказа приложения не нарисована'),
        false
    )

    -- А вот сорвавшаяся страница и страница, отдавшая не разметку, —
    -- это опечатка в шаблоне, и о ней пишется в журнал.
    local fallen = missing({
        page = function()
            error('в шаблоне опечатка')
        end,
    })

    t.assert_str_contains(fallen.body, '<h1>Страницы нет</h1>')
    t.assert_equals(helper.logged('в шаблоне опечатка'), true)

    local odd = missing({
        page = function()
            return 7
        end,
    })

    t.assert_str_contains(odd.body, '<h1>Страницы нет</h1>')
    t.assert_equals(helper.logged('страница отдала number'), true)
end

g.test_the_page_is_switched_off_by_the_setting = function()
    -- API, которому страница не нужна вовсе: браузер получает то же тело,
    -- что и сценарий.
    local body = missing({ page = false })

    t.assert_equals(body.headers['content-type'], 'application/problem+json')
    t.assert_equals(helper.body(body).detail, 'Клиента №7 нет')
end

g.test_the_settings_name_the_page_and_refuse_what_is_not_a_page = function()
    local page = helper.part('tnt.error.page')
    local own = function()
        return '<p></p>'
    end

    t.assert_equals(page.name_of(true), 'builtin')
    t.assert_equals(page.name_of(false), 'off')
    t.assert_equals(page.name_of(own), 'custom')

    t.assert_equals(g.errors.registry({ page = own }):status().page, 'custom')
    t.assert_equals(g.errors.registry({ page = false }):status().page, 'off')
    t.assert_equals(g.errors.registry({ debug = true }):status().debug, true)

    helper.refuses(function()
        g.errors.registry({ page = 'errors.404' })
    end, 'страница отказа должна быть true, false либо своей функцией')

    helper.refuses(
        function()
            g.errors.registry({ debug = 'yes' })
        end,
        'разбор поломки на странице должен быть логическим значением'
    )
end

return g
