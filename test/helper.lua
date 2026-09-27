--- Общие средства тестов пакета отказов.
---
--- Исходники читаются с диска, а не через `require`: у Tarantool свой
--- загрузчик `.rocks`, он идёт раньше `package.path` и подсунул бы
--- установленную копию пакета, если она есть. Проверки тогда шли бы
--- против вчерашнего кода, а покрытие считалось бы по нему. Зависимости
--- пакета — `tnt.log`, `tnt.context`, `tnt.id`, `tnt.template`,
--- `tnt.validate` и `tnt.external` — и сосед стыка `tnt.router` берутся
--- из `.rocks` обычным `require`: проверяется этот пакет, а не они.
---
--- Оснастка в `test/testing/` — загрузчик исходников и ловушка журнала —
--- грузится так же, файлами, и один раз на процесс: второй экземпляр
--- загрузчика не знал бы, что вытеснил первый, и не вернул бы вытесненное
--- на место.
---
--- Проверки пакета берут всё через помощник, а не из оснастки напрямую:
--- помощник — единственное, чем файл проверок отличается от того же файла
--- в репозитории, где пакет живёт рядом со своими зависимостями.

local fio = require('fio')
local t = require('luatest')

--- Модули оснастки в порядке зависимостей: ловушка журнала берёт
--- загрузчик.
local TESTING = {
    { name = 'tnt.testing.sources', path = 'test/testing/sources.lua' },
    { name = 'tnt.testing.journal', path = 'test/testing/journal.lua' },
}

for _, module in ipairs(TESTING) do
    if package.loaded[module.name] == nil then
        local chunk, failure = loadfile(fio.abspath(module.path))

        if chunk == nil then
            error(('оснастка %s не читается: %s'):format(module.name, tostring(failure)))
        end

        package.loaded[module.name] = chunk()
    end
end

--- Оснастка проверок под теми именами, что зовёт помощник.
local testing = {
    load_sources = package.loaded['tnt.testing.sources'].load,
    unload_sources = package.loaded['tnt.testing.sources'].unload,
    module = package.loaded['tnt.testing.sources'].module,
    capture_log = package.loaded['tnt.testing.journal'].capture,
}

local helper = {}

--- Части пакета отказов в порядке зависимостей.
local OWN_PARTS = {
    'secret',
    'failure',
    'hook',
    'incident',
    'catalog',
    'render',
    'accept',
    'options',
    'page',
    'translation',
    'web',
}

--- Модули пакета в порядке зависимостей.
helper.MODULES = {}

for _, part in ipairs(OWN_PARTS) do
    table.insert(helper.MODULES, { name = 'tnt.error.' .. part, path = ('tnt/error/%s.lua'):format(part) })
end

table.insert(helper.MODULES, { name = 'tnt.error', path = 'tnt/error.lua' })

--- Роутер для проверок стыка — из `.rocks`, и берётся сразу, без `pcall`:
--- нет его — `make deps` не сделан, и сказать об этом надо сразу, а не
--- пропуском проверок стыка.
local router = require('tnt.router')

--- Опознаватель, который выдаёт подменённая случайность в проверках.
helper.INCIDENT = '0000-0000'

local journal = testing.capture_log()

--- Была ли запись журнала с такой подстрокой.
---
--- Ловушка ставится всем группам пакета без спроса: внутренняя поломка
--- уходит в журнал всегда, и проверка, не поймавшая запись, вывела бы
--- её в вывод самого прогона.
---@type fun(fragment: string): boolean
helper.logged = journal.logged

--- Забывает пойманные записи: проверке, перебирающей случаи, нужна
--- запись своего случая, а не первого.
helper.forget = journal.forget

--- Причина из записи о внутренней поломке — такой, какой её отдал журнал.
---
--- Читается поле записи, а не строка: причина-таблица ложится туда JSON,
--- и сверять его надо разобранным — порядок пар у таблицы не задан.
---@return any
function helper.reason()
    return helper.record().fields.reason
end

--- Запись о внутренней поломке целиком — с полями, как её отдал журнал.
---@return table
function helper.record()
    local entry = assert(
        journal.find('внутренняя поломка'),
        'записи о внутренней поломке нет'
    )

    return entry.record
end

--- Поля первой записи журнала с такой подстрокой либо nil.
---
--- Сверяются поля, а не строка записи: причина в ней лежит полем,
--- и строкой её пришлось бы выковыривать.
---@param fragment string
---@return table|nil
function helper.fields(fragment)
    local entry = journal.find(fragment)

    return entry ~= nil and entry.record.fields or nil
end

--- Отдельный модуль пакета, уже загруженный группой.
---@param name string
---@return any
function helper.part(name)
    return testing.module(name)
end

--- Готовит проверку: свежие исходники, предсказуемая случайность, пустой
--- журнал.
---
--- Случайность подменяется сразу: опознаватель попадает и в ответ,
--- и в запись журнала, и сравнивать их можно только с предсказуемым.
---@param g table
local function arm(g)
    g.errors = testing.load_sources(helper.MODULES, 'tnt.error')

    helper.part('tnt.error.incident')._set_source({
        random = function(count)
            return string.rep('\0', count)
        end,
    })

    journal.forget()
end

--- Заводит группу проверок с готовым фасадом в `g.errors`.
---
--- Исходники убираются за каждой проверкой: общий каталог живёт в модуле,
--- и объявления, сделанные одной проверкой, достались бы следующей —
--- а повторное объявление кода пакет считает отказом.
---@param name string
---@return table g Группа luatest; фасад пакета лежит в `g.errors`
function helper.group(name)
    local g = t.group(name)

    g.before_each(function()
        arm(g)
    end)

    g.after_each(function()
        testing.unload_sources(helper.MODULES)
    end)

    return g
end

--- Заводит группу проверок, в которой рядом с отказами живёт роутер.
---
--- Роутер один на процесс — установленная копия, — и подмену его
--- случайности проверка стыка ставит сама. После каждой проверки
--- роутер получает свою случайность назад: подмена одной проверки
--- досталась бы следующей.
---@param name string
---@return table g Группа luatest; фасады лежат в `g.errors` и `g.router`
function helper.routed_group(name)
    local g = t.group(name)

    g.before_each(function()
        arm(g)

        g.router = router
    end)

    g.after_each(function()
        testing.unload_sources(helper.MODULES)
        helper.part('tnt.router.errors')._set_source(nil)
    end)

    return g
end

--- Разобранное тело готового ответа.
---
--- `response` отдаёт тело строкой: ответ уходит в `http.server` как есть,
--- а таблицу тот печатает клиенту как «table: 0x...». Проверкам нужны
--- поля, и разбирать строку они обязаны так же, как это сделает клиент.
---@param response table
---@return any
function helper.body(response)
    return require('json').decode(response.body)
end

--- Объявляет отказ «нет такого клиента» — на нём проверяется почти всё.
---@param errors table Фасад пакета
---@return string code
function helper.declare_customer(errors)
    return errors.define('customer.not_found', {
        status = 404,
        message = 'Клиента №{id} нет',
    })
end

--- Что пакет считает недопустимым: вызов обязан сорваться исключением.
---@param act fun() Что сделать
---@param fragment string Что должно быть сказано в отказе
function helper.refuses(act, fragment)
    local ok, refusal = pcall(act)

    t.assert_equals(ok, false, 'вызов прошёл, хотя должен был сорваться')
    t.assert_str_contains(tostring(refusal), fragment)
end

return helper
