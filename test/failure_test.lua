--- Тесты отказа как значения: цепочка причин и опознание своего отказа.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.error.failure')

--- Модуль отказов, загруженный группой.
---@return any
local function failure()
    return helper.part('tnt.error.failure')
end

--- Слой цепочки с заданной строкой и причиной.
---@param message string
---@param cause any
---@return any
local function layer(message, cause)
    return failure().new({ message = message, cause = cause })
end

g.test_chain_keeps_every_layer_from_the_top_down = function()
    local err = layer(
        'письмо не ушло',
        layer('соединение не открылось', layer('сервер молчит'))
    )

    t.assert_equals(failure().chain(err), {
        'письмо не ушло',
        'соединение не открылось',
        'сервер молчит',
    })
end

g.test_whole_chain_reads_as_one_sentence = function()
    local err = layer('письмо не ушло', layer('сервер молчит'))

    t.assert_equals(tostring(err), 'письмо не ушло: сервер молчит')
end

g.test_a_foreign_cause_ends_the_chain_by_its_own_text = function()
    -- Чужой отказ разбирать нечем: у него своё устройство, и лезть в него
    -- значит гадать. Берётся то единственное, что у него точно есть.
    local err = layer('письмо не ушло', 42)

    t.assert_equals(failure().chain(err), { 'письмо не ушло', '42' })
end

g.test_only_our_own_failure_is_recognized_as_ours = function()
    t.assert_equals(failure().is(layer('сервер молчит')), true)
    t.assert_equals(failure().is('сервер молчит'), false)
    t.assert_equals(failure().is({ message = 'сервер молчит' }), false)
    t.assert_equals(failure().is(nil), false)
end

g.test_a_foreign_refusal_is_recognized_by_the_number_in_its_status = function()
    -- Признак договора границы HTTP один и он явный: по виду прочих полей
    -- пакет ничего не решает — догадку отсюда убрали, и заводить её заново
    -- под другим именем нельзя.
    t.assert_equals(failure().refuses({ status = 404 }), true)
    t.assert_equals(failure().refuses({ status = 500, message = 'занято' }), true)
end

g.test_the_edges_of_the_range_of_refusals_are_refusals_too = function()
    -- Отказ — это 4xx и 5xx. Таблица с успешным статусом — ответ, а не
    -- отказ: принять её за отказ значило бы молча превратить промах
    -- вызывающего в готовый ответ клиенту.
    t.assert_equals(failure().refuses({ status = 400 }), true)
    t.assert_equals(failure().refuses({ status = 599 }), true)
    t.assert_equals(failure().refuses({ status = 399 }), false)
    t.assert_equals(failure().refuses({ status = 600 }), false)
end

g.test_anything_that_did_not_name_a_status_is_not_a_refusal = function()
    t.assert_equals(failure().refuses('сервер молчит'), false)
    t.assert_equals(failure().refuses(nil), false)
    t.assert_equals(failure().refuses(404), false)
    t.assert_equals(failure().refuses({}), false)
    t.assert_equals(failure().refuses({ status = 'ok' }), false)
    -- Запись работы с числовым состоянием — не отказ HTTP.
    t.assert_equals(failure().refuses({ status = 1 }), false)
    t.assert_equals(failure().refuses({ status = 404.5 }), false)
end

g.test_a_refusal_thrown_under_a_foreign_catch_is_found_in_its_field = function()
    -- Конвейер слоёв кладёт брошенное в отказ упавшего шага полем
    -- `raised`: наш отказ узнаётся там по метатаблице, чужой отказ
    -- границы — по числу в `status`, а прочее брошенное отказом не считается.
    local ours = layer('клиента нет')
    local foreign = { status = 409, message = 'счёт уже закрыт' }

    t.assert_is(failure().thrown({ raised = ours }), ours)
    t.assert_is(failure().thrown({ message = 'обработчик упал: …', raised = foreign }), foreign)
    t.assert_equals(failure().thrown({ raised = 'сервер молчит' }), nil)
    t.assert_equals(failure().thrown({ raised = { status = 200 } }), nil)
    t.assert_equals(failure().thrown({}), nil)
    t.assert_equals(failure().thrown('сервер молчит'), nil)
    t.assert_equals(failure().thrown(nil), nil)
end

--- Отказ с причиной-отказом, чужой причиной и всем, что в запись не идёт.
---@return any
local function whole()
    return failure().new({
        code = 'mail.not_sent',
        status = 502,
        title = 'Письмо не ушло',
        type = 'about:blank',
        message = 'письмо на postgres://root:hunter2@db не ушло',
        expected = false,
        incident = '0000-0000',
        headers = { ['retry-after'] = '5' },
        params = { to = 'ivan@example.org' },
        traceback = 'stack traceback: hunter2',
        cause = failure().new({
            code = 'smtp.down',
            status = 503,
            message = 'сервер молчит',
            cause = 'соединение token=hunter2 отвергнуто',
        }),
    })
end

g.test_a_failure_serializes_to_the_fields_it_is_found_by = function()
    local err = whole()

    t.assert_equals(getmetatable(err).__serialize(err), {
        code = 'mail.not_sent',
        status = 502,
        message = 'письмо на postgres://root:hunter2@db не ушло',
        incident = '0000-0000',
        cause = err.cause,
    })
end

g.test_a_failure_in_the_journal_is_fields_without_secrets_or_stack = function()
    -- Настоящий фасад журнала с двойником ядра: проверяется ровно то,
    -- что ушло бы в запись, а не то, что отдаёт `__serialize`.
    local journal = helper.part('tnt.log')
    local written = {}

    local function write(record)
        table.insert(written, record)
    end

    journal._set_source({
        logger = function()
            return { debug = write, info = write, warn = write, error = write }
        end,
        settings = function()
            return { level = 'debug', format = 'json' }
        end,
    })

    journal.new('tnt.error.test').warn('запрос не прошёл', { err = whole() })

    t.assert_equals(written[1].fields.err, {
        code = 'mail.not_sent',
        status = 502,
        message = 'письмо на postgres://root:' .. journal.HIDDEN .. '@db не ушло',
        incident = '0000-0000',
        cause = {
            code = 'smtp.down',
            status = 503,
            message = 'сервер молчит',
            cause = 'соединение token=' .. journal.HIDDEN .. ' отвергнуто',
        },
    })
end
