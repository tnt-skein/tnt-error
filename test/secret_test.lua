--- Тесты вырезания тайн: имена полей, адреса с паролем, строка запроса.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.error.secret')

--- Модуль вырезания, загруженный группой.
---@return any
local function secret()
    return helper.part('tnt.error.secret')
end

g.test_names_that_look_like_a_secret_are_recognized = function()
    t.assert_equals(secret().secret('password'), true)
    t.assert_equals(secret().secret('db_password'), true)
    t.assert_equals(secret().secret('Authorization'), true)
    t.assert_equals(secret().secret('refresh_token'), true)
    t.assert_equals(secret().secret('private_key'), true)
    t.assert_equals(secret().secret('apikey'), true)
    t.assert_equals(secret().secret('passwd'), true)
    t.assert_equals(secret().secret('secret_word'), true)
    t.assert_equals(secret().secret('cookie'), true)
end

g.test_names_that_do_not_look_like_a_secret_are_left_alone = function()
    t.assert_equals(secret().secret('id'), false)
    t.assert_equals(secret().secret('host'), false)
    t.assert_equals(secret().secret(7), false)
    t.assert_equals(secret().secret(nil), false)
end

g.test_a_hyphen_in_a_header_name_counts_as_an_underscore = function()
    -- Список писался под имена полей, а заголовок зовётся через дефис:
    -- без приведения ключ в заголовке уехал бы наружу.
    t.assert_equals(secret().secret('X-Api-Key'), true)
    t.assert_equals(secret().secret('x-auth-token'), true)
end

g.test_hints_come_from_the_journal = function()
    -- Список один на двоих, и живёт он в журнале: приложение, дописавшее
    -- туда своё имя поля, прячет его и в записях, и в ответах — одной
    -- правкой, а не двумя.
    ---@type any
    local journal = require('tnt.log')
    local kept = journal.secret_hints

    journal.secret_hints = { 'дверь' }

    t.assert_equals(secret().secret('чёрная_дверь'), true)
    -- Список журнала — единственный: свой пакет отказов не держит,
    -- иначе два списка однажды разъехались бы молча.
    t.assert_equals(secret().secret('password'), false)

    journal.secret_hints = kept

    t.assert_equals(secret().secret('password'), true, 'обычный список вернулся')
end

g.test_a_name_from_the_list_is_read_as_plain_text = function()
    -- Имена в списке пишет человек, а не тот, кто умеет образцы поиска:
    -- точка в имени должна означать точку, а не «любой знак».
    ---@type any
    local journal = require('tnt.log')

    local kept = journal.secret_hints

    journal.secret_hints = { 'api.key' }

    t.assert_equals(secret().secret('api.key'), true)
    t.assert_equals(secret().secret('apiXkey'), false)

    journal.secret_hints = kept
end

g.test_password_inside_an_address_is_hidden_and_the_rest_stays = function()
    t.assert_equals(
        secret().scrub('postgres://root:hunter2@db:5432/main'),
        'postgres://root:' .. secret().HIDDEN .. '@db:5432/main'
    )
end

g.test_an_empty_login_does_not_save_the_password = function()
    -- Адрес с пустым логином встречается, и пароль в нём такой же.
    t.assert_equals(secret().scrub('http://:hunter2@db'), 'http://:' .. secret().HIDDEN .. '@db')
end

g.test_address_without_a_password_is_left_as_it_is = function()
    t.assert_equals(secret().scrub('http://db:5432/main'), 'http://db:5432/main')
    t.assert_equals(secret().scrub('http://root:@db'), 'http://root:@db')
end

g.test_a_port_is_not_mistaken_for_a_password = function()
    -- Иначе `узел:3301/записи@главная` разбирается как пароль
    -- `3301/записи`, и вместо тайны прячется порт.
    local address = 'http://tarantool:3301/logs@main'

    t.assert_equals(secret().scrub(address), address)
end

g.test_a_colon_in_the_path_is_not_a_password = function()
    t.assert_equals(secret().scrub('http://db/users:7@list'), 'http://db/users:7@list')
end

g.test_query_string_hides_only_the_suspicious_parameter = function()
    t.assert_equals(
        secret().scrub('/enter?login=ivan&token=abc123&page=2'),
        '/enter?login=ivan&token=' .. secret().HIDDEN .. '&page=2'
    )
end

g.test_a_parameter_named_through_a_hyphen_is_hidden_too = function()
    -- Имя параметра пишут через дефис куда чаще, чем через подчёркивание.
    t.assert_equals(secret().scrub('/enter?api-key=abc123'), '/enter?api-key=' .. secret().HIDDEN)
end

g.test_a_parameter_without_a_value_is_left_alone = function()
    -- Прятать нечего, а заглушка на пустом месте сказала бы, что значение
    -- было.
    t.assert_equals(secret().scrub('/enter?token=&page=2'), '/enter?token=&page=2')
end

g.test_scrubbing_touches_strings_only = function()
    t.assert_equals(secret().scrub(7), 7)
    t.assert_equals(secret().scrub(nil), nil)
end

g.test_value_under_a_secret_name_is_replaced_whole = function()
    t.assert_equals(secret().clean('password', 'hunter2'), secret().HIDDEN)
end

g.test_cleaning_goes_into_nested_tables_and_copies_them = function()
    local given = { db = { host = 'db', password = 'hunter2' }, id = 7 }
    local clean = secret().clean(nil, given)

    t.assert_equals(clean, { db = { host = 'db', password = secret().HIDDEN }, id = 7 })
    -- Исходная таблица не тронута: она принадлежит тому, кто заводил отказ.
    t.assert_equals(given.db.password, 'hunter2')
end

g.test_cleaning_hides_a_password_hidden_inside_an_ordinary_field = function()
    local clean = secret().clean(nil, { url = 'amqp://bus:swordfish@rabbit' })

    t.assert_equals(clean.url, 'amqp://bus:' .. secret().HIDDEN .. '@rabbit')
end

g.test_a_table_pointing_at_itself_does_not_take_the_node_down = function()
    local ring = { id = 7 }

    ring.self = ring

    t.assert_equals(secret().clean(nil, ring), { id = 7, self = secret().CYCLE })
end

g.test_the_same_table_in_two_fields_is_not_a_ring = function()
    -- Кольцо — это ссылка внутрь себя, а не две ссылки на одно и то же:
    -- второе законно, и прятать его значило бы терять данные.
    local shared = { host = 'db' }
    local clean = secret().clean(nil, { left = shared, right = shared })

    t.assert_equals(clean, { left = { host = 'db' }, right = { host = 'db' } })
end
