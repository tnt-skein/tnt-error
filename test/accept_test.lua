--- Проверки согласования: кому уходит страница, а кому прежнее тело.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.error.accept')

--- Просит ли страницу клиент с таким заголовком.
---@param accept any
---@return boolean
local function wants(accept)
    return helper.part('tnt.error.accept').wants_page({ headers = { accept = accept } })
end

g.test_the_header_is_named_once_and_in_lower_case = function()
    -- Имена заголовков запроса приходят в нижнем регистре — это договор
    -- границы HTTP, и второго написания здесь не ищут.
    t.assert_equals(helper.part('tnt.error.accept').HEADER, 'accept')
end

g.test_a_browser_gets_a_page_and_a_script_gets_the_body = function()
    -- Заголовок браузера — как его шлют Chrome и Firefox.
    t.assert_equals(wants('text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,*/*;q=0.8'), true)

    -- `curl` и `fetch` без заголовка: клиенту всё равно, и менять из-за
    -- этого договор тела нельзя.
    t.assert_equals(wants('*/*'), false)
    t.assert_equals(wants('application/json'), false)
    t.assert_equals(wants('application/problem+json'), false)
end

g.test_the_weight_decides_when_both_kinds_are_named = function()
    -- Клиент API, готовый и на страницу, называет оба вида, и решает вес.
    t.assert_equals(wants('application/json, text/html;q=0.1'), false)
    t.assert_equals(wants('text/html, application/json;q=0.5'), true)
    t.assert_equals(wants('text/html;q=0.5, application/json;q=0.2'), true)

    -- Равный вес — данным: клиент, назвавший оба одинаково, ничего
    -- о себе не сказал.
    t.assert_equals(wants('application/json, text/html'), false)
    t.assert_equals(wants('text/html;q=0.5, application/json;q=0.5'), false)

    -- Наибольший вес из названных: один и тот же вид называют дважды.
    t.assert_equals(wants('text/html;q=0.1, text/html;q=0.9, application/json;q=0.5'), true)

    -- Нулевой вес — это «не присылайте вовсе».
    t.assert_equals(wants('text/html;q=0'), false)
    t.assert_equals(wants('text/html;q=0, application/json;q=0'), false)

    -- Тело просят обоими своими видами, и вес у них считается тот же.
    t.assert_equals(wants('application/problem+json, text/html;q=0.5'), false)
end

g.test_the_page_is_asked_for_by_name_and_nothing_else = function()
    -- Страницу просят прямо: подстановочный вид её не просит.
    t.assert_equals(wants('text/*'), false)
    t.assert_equals(wants('text/plain'), false)
    t.assert_equals(wants(''), false)

    -- Браузер называет и второе имя страницы; клиент, назвавший только
    -- его, просит ровно её.
    t.assert_equals(wants('application/xhtml+xml'), true)

    -- Вид пишется как угодно: RFC не велит различать регистр.
    t.assert_equals(wants('TEXT/HTML'), true)
    t.assert_equals(wants(' text/html '), true)
end

g.test_a_broken_weight_is_read_as_a_full_one = function()
    -- Заголовок пишет клиент, и отказывать ему в ответе об отказе
    -- из-за мусора в нём было бы дурной шуткой: негодный вес — единица.
    t.assert_equals(wants('text/html;q=абв'), true)
    t.assert_equals(wants('text/html;q=7'), true)
    -- Записью RFC не считается ни это, ни дробь без нуля впереди.
    t.assert_equals(wants('text/html;q=-1'), true)
    t.assert_equals(wants('text/html;q=1.2.3'), true)
    t.assert_equals(wants('application/json, text/html;q=.9'), false)

    -- Вес больше единицы читается как единица, а не как «важнее всего»:
    -- иначе `q=1.5` перебивал бы названный без веса.
    t.assert_equals(wants('text/html, application/json;q=1.5'), false)
    t.assert_equals(wants('text/html;q=1.5, application/json;q=0.5'), true)

    -- Прочие параметры вида на выбор не влияют, а `q` среди них находится.
    t.assert_equals(wants('text/html;level=1;q=0.4, application/json;q=0.5'), false)
    t.assert_equals(wants('text/html;charset=utf-8'), true)
    -- Имя, начинающееся с `q`, весом не является.
    t.assert_equals(wants('text/html;quality=0.1, application/json;q=0.5'), true)
end

g.test_a_request_without_the_header_asks_for_nothing = function()
    local accept = helper.part('tnt.error.accept')

    t.assert_equals(accept.wants_page(nil), false)
    t.assert_equals(accept.wants_page('GET /'), false)
    t.assert_equals(accept.wants_page({}), false)
    t.assert_equals(accept.wants_page({ headers = 'accept: text/html' }), false)
    t.assert_equals(accept.wants_page({ headers = {} }), false)
    t.assert_equals(wants(7), false)
end

return g
