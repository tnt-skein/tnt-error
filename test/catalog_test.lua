--- Тесты каталога отказов: вид кода, объявление, подстановки.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.error.catalog')

--- Модуль каталога, загруженный группой.
---@return any
local function catalog()
    return helper.part('tnt.error.catalog')
end

--- Свежий каталог: в нём объявлена одна внутренняя поломка.
---@return any
local function fresh()
    return catalog().new()
end

g.test_a_code_is_lowercase_latin_split_by_dots = function()
    t.assert_equals(catalog().is_code('internal'), true)
    t.assert_equals(catalog().is_code('customer.not_found'), true)
    t.assert_equals(catalog().is_code('a.b.c2'), true)
end

g.test_anything_a_human_would_write_is_not_a_code = function()
    -- Разница нужна там, где на месте кода допускается и строка для
    -- человека: спутав их, обёртка показала бы клиенту слово `internal`.
    t.assert_equals(catalog().is_code('письмо не ушло'), false)
    t.assert_equals(catalog().is_code('mail failed'), false)
    t.assert_equals(catalog().is_code('Customer.NotFound'), false)
    t.assert_equals(catalog().is_code('2fast'), false)
    t.assert_equals(catalog().is_code('customer..name'), false)
    t.assert_equals(catalog().is_code('customer.'), false)
    t.assert_equals(catalog().is_code('.customer'), false)
    t.assert_equals(catalog().is_code(''), false)
    t.assert_equals(catalog().is_code(42), false)
    t.assert_equals(catalog().is_code(nil), false)
    t.assert_equals(catalog().is_code(true), false)
end

g.test_named_substitutions_are_taken_by_name = function()
    t.assert_equals(catalog().fill('Клиента №{id} нет', { id = 7 }), 'Клиента №7 нет')
    -- Имя в одну букву — такое же имя, как всякое другое.
    t.assert_equals(catalog().fill('осталось {n}', { n = 3 }), 'осталось 3')
end

g.test_substitutions_by_order_are_taken_from_the_list = function()
    t.assert_equals(catalog().fill('%s из %s', { 'первое', 'второе' }), 'первое из второе')
end

g.test_a_substitution_with_nothing_to_put_stays_visible = function()
    -- Пустое место выглядит законченной фразой и доживает до продакшена,
    -- а оставшаяся подстановка сразу говорит, чего не передали.
    t.assert_equals(catalog().fill('Клиента №{id} нет', {}), 'Клиента №{id} нет')
    t.assert_equals(catalog().fill('нет %s', {}), 'нет %s')
end

g.test_a_template_without_substitutions_is_left_alone = function()
    t.assert_equals(catalog().fill('Клиента нет', { id = 7 }), 'Клиента нет')
end

g.test_declaration_comes_back_by_its_code = function()
    local known = fresh()

    local code = known:define('customer.not_found', { status = 404, message = 'Нет' })

    t.assert_equals(code, 'customer.not_found')
    t.assert_equals(known:find('customer.not_found').status, 404)
end

g.test_the_template_becomes_the_name_of_the_kind_when_none_is_given = function()
    -- Имя рода обязано быть одним и тем же от случая к случаю, а шаблон
    -- как раз таков: подстановки в нём ещё не сделаны.
    local known = fresh()

    known:define('customer.not_found', { status = 404, message = 'Клиента №{id} нет' })

    t.assert_equals(known:find('customer.not_found').title, 'Клиента №{id} нет')
end

g.test_a_given_name_of_the_kind_wins = function()
    local known = fresh()

    known:define('customer.not_found', {
        status = 404,
        message = 'Клиента №{id} нет',
        title = 'Клиент не найден',
    })

    t.assert_equals(known:find('customer.not_found').title, 'Клиент не найден')
end

g.test_asking_for_something_that_is_not_a_code_gives_nothing = function()
    local known = fresh()

    t.assert_equals(known:find('customer.not_found'), nil)
    t.assert_equals(known:find(42), nil)
    t.assert_equals(known:find(nil), nil)
end

g.test_a_code_of_the_wrong_shape_is_refused_at_once = function()
    helper.refuses(function()
        fresh():define('Customer.NotFound', { status = 404, message = 'Нет' })
    end, 'код отказа Customer.NotFound непригоден')
end

g.test_declaring_a_taken_code_twice_is_refused = function()
    local known = fresh()

    known:define('customer.not_found', { status = 404, message = 'Нет' })

    helper.refuses(function()
        known:define('customer.not_found', { status = 410, message = 'Нету' })
    end, 'отказ customer.not_found уже объявлен')
end

g.test_redefining_puts_the_new_declaration_in_place_of_the_old = function()
    -- Слово пакета написано для всех приложений сразу, и своему человеку
    -- приложение говорит иначе.
    local known = fresh()

    known:define('customer.not_found', { status = 404, message = 'Нет' })

    local code = known:redefine('customer.not_found', { status = 410, message = 'Ушёл' })

    t.assert_equals(code, 'customer.not_found')
    t.assert_equals(known:find('customer.not_found'), {
        status = 410,
        message = 'Ушёл',
        title = 'Ушёл',
    })
    t.assert_equals(known:codes(), { 'customer.not_found', 'internal' })
end

g.test_the_internal_breakage_is_declared_in_every_catalogue_from_the_start = function()
    -- Паника — не то место, где выясняют, есть ли чем на неё ответить.
    local declared = fresh():find(catalog().INTERNAL)

    t.assert_equals(declared.status, 500)
    t.assert_equals(declared.title, 'Внутренняя ошибка')
    t.assert_str_contains(declared.message, '{incident}')
end

g.test_the_word_of_the_internal_breakage_has_to_name_the_incident = function()
    -- Проверка стоит у самих данных, а не этажом выше: каталог открыт
    -- полем реестра, и запертая одна дверь из двух не заперта вовсе.
    local known = fresh()

    helper.refuses(function()
        known:redefine(catalog().INTERNAL, { status = 503, message = 'Что-то пошло не так' })
    end, 'слово внутренней поломки обязано называть {incident}')

    -- Негодная замена не стирает прежнего слова.
    t.assert_str_contains(known:find(catalog().INTERNAL).message, '{incident}')

    local code = known:redefine(catalog().INTERNAL, {
        status = 503,
        message = 'Панель прилегла. Назовите {incident} дежурному.',
    })

    t.assert_equals(code, 'internal')
    t.assert_equals(known:find(catalog().INTERNAL).status, 503)
end

g.test_redefining_a_code_nobody_declared_is_refused = function()
    -- Иначе опечатка в коде заводит рядом второй отказ о том же самом,
    -- и о нём никто не узнает: вызов прошёл, слово не поменялось.
    local known = fresh()

    helper.refuses(function()
        known:redefine('customer.not_found', { status = 410, message = 'Ушёл' })
    end, 'отказ customer.not_found не объявлен: переопределять нечего')

    helper.refuses(function()
        known:redefine(42, { status = 410, message = 'Ушёл' })
    end, 'отказ 42 не объявлен')
end

g.test_a_new_declaration_is_checked_the_same_as_the_first_one = function()
    local known = fresh()

    known:define('customer.not_found', { status = 404, message = 'Нет' })

    helper.refuses(function()
        known:redefine('customer.not_found', { status = 4004, message = 'Ушёл' })
    end, 'статус ответа должен быть целым числом от 100 до 599')

    -- Негодная замена не стирает того, что было: отвечать всё равно чем-то
    -- надо, а объявления уже нет.
    t.assert_equals(known:find('customer.not_found').status, 404)
end

g.test_a_declaration_that_does_not_hold_together_is_refused = function()
    helper.refuses(function()
        fresh():define('customer.not_found', { status = 4004, message = 'Нет' })
    end, 'статус ответа должен быть целым числом от 100 до 599')

    helper.refuses(function()
        fresh():define('customer.not_found', { status = 404 })
    end, 'строка для человека обязательна')

    helper.refuses(function()
        fresh():define('customer.not_found')
    end, 'статус ответа обязателен')
end

g.test_an_empty_string_is_not_a_string_for_a_human = function()
    -- Пустая строка в ответе выглядит поломкой ответа, а не отказом,
    -- и понять по ней нечего.
    helper.refuses(
        function()
            fresh():define('customer.not_found', { status = 404, message = '' })
        end,
        'строка для человека должна быть строкой длиной не меньше 1 знака'
    )

    helper.refuses(
        function()
            fresh():define('customer.not_found', { status = 404, message = 'Нет', title = '' })
        end,
        'имя рода отказа должно быть строкой длиной не меньше 1 знака'
    )

    helper.refuses(function()
        fresh():define('customer.not_found', { status = 404, message = 'Нет', type = '' })
    end, 'URI рода отказа должен быть строкой длиной не меньше 1 знака')
end

g.test_a_string_of_one_letter_is_a_string_all_the_same = function()
    local known = fresh()

    known:define('customer.gone', { status = 410, message = 'Х', title = 'И', type = 'u' })

    t.assert_equals(known:find('customer.gone'), {
        status = 410,
        message = 'Х',
        title = 'И',
        type = 'u',
    })
end

g.test_codes_come_back_in_one_order = function()
    -- Поля таблицы в Lua обходятся как попало, и список без порядка
    -- читался бы каждый раз по-новому.
    local known = fresh()

    known:define('mail.not_sent', { status = 502, message = 'Не ушло' })
    known:define('customer.not_found', { status = 404, message = 'Нет' })

    t.assert_equals(known:codes(), { 'customer.not_found', 'internal', 'mail.not_sent' })
    t.assert_equals(fresh():codes(), { 'internal' })
end
