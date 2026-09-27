--- Вырезание тайн из того, что уходит человеку и в журнал.
---
--- Отказ почти всегда несёт с собой то, из-за чего он случился, а это
--- ровно те данные, которые прислал клиент: заголовок с ключом, строка
--- запроса с токеном, адрес базы с паролем. Ни один из них не должен
--- попасть ни в ответ, ни в запись журнала — ответ читает посторонний,
--- а журнал живёт годами и уезжает в чужой сборщик.
---
--- **Правило живёт в журнале, здесь только ссылки на него.** `secret`
--- (похоже ли имя на тайну) и `scrub` (тайны внутри строки) раньше были
--- написаны здесь, а у журнала была своя копия — и копии разъехались:
--- журнал не приводил дефис к подчёркиванию, и `X-Api-Key` в записи был
--- виден, а в ответе спрятан. Пароль, спрятанный в ответе и уехавший
--- в журнал, спрятан только наполовину. Правило переехало в `tnt-log`,
--- а не наоборот: пакет отказов зависит от журнала, и журнал брать правило
--- отсюда не может.
---
--- Здесь остаются `clean` — копия подстановок без тайн: она нужна ответу,
--- а журнал очищает значения своим обходом, у которого другие заботы —
--- потолок записи и значения, на которых бросает ядро, — и `describe` —
--- причина поломки одной строкой без тайн. Строкой, а не таблицей: поле
--- записи, которое бывает то строкой, то объектом, сборщик журналов
--- не разложит по одной схеме, а цепочка отказа печатает причину текстом.

local ffi = require('ffi')
local json = require('json')
local utf8 = require('utf8')

local journal = require('tnt.log')

---@class TntErrorSecret
---@field secret fun(name: any): boolean Похоже ли имя на тайну
---@field scrub fun(value: any): any Тайны внутри строки спрятаны
local Module = {}

--- Чем заменяется тайна: слово журнала, чтобы заглушка читалась одинаково
--- и в ответе, и в записи.
Module.HIDDEN = journal.HIDDEN

--- Что ставится вместо таблицы, сославшейся на саму себя.
---
--- Кольцо в подстановках заводится не злым умыслом, а ссылкой на объект,
--- который держит ссылку назад. Без остановки обход такой таблицы уводит
--- в бесконечность и роняет узел переполнением стека — то есть отказ,
--- который собирались показать человеку, убивает процесс.
Module.CYCLE = journal.CYCLE

--- Сколько уровней таблицы-причины попадает в описание.
---
--- Человек теряет нить задолго до восьмого уровня, а восемь оставляют
--- запас на обёртки чужих библиотек. Предел нужен и сам по себе: `json`
--- бросает на сто двадцать девятом уровне, а обход без предела переполнил
--- бы стек.
Module.DEPTH = 8

--- Сколько пар всего попадает в описание — на всех уровнях вместе.
---
--- Описание — не выгрузка: по шестидесяти четырём парам видно, что
--- сломалось. Таблица на миллион пар без предела копировалась бы целиком
--- ради строки, которую журнал всё равно обрежет по своему потолку.
Module.ENTRIES = 64

--- Похоже ли имя на тайну. Список имён — `secret_hints` журнала, и читается
--- он при каждом обращении: приложение вправе дописать туда своё имя позже,
--- чем загрузились пакеты.
Module.secret = journal.secret

--- Прячет тайны внутри строки: пароль в адресе и значение подозрительного
--- параметра. Не строка возвращается как есть.
Module.scrub = journal.scrub

--- Что ставится вместо таблицы глубже предела: то же слово, каким журнал
--- помечает слишком глубокие поля.
local DEEP = '[глубже]'

--- Чем помечено описание, в которое вошли не все пары: тот же знак, каким
--- журнал помечает обрезанную строку.
local CUT = '…'

--- Граница целых, которые double хранит без потерь. Ключ больше неё `json`
--- пишет с потерей цифр, а ключ вне int64 не берёт вовсе и бросает.
local EXACT_INTEGER = 2 ^ 53

--- Роды значений, которые `json` пишет сам и без отказа.
---
--- Строк здесь нет: их печать — они сами, и проверять у них надо другое —
--- годятся ли они в UTF-8.
---@type table<string, boolean>
local KEPT = { number = true, boolean = true }

--- Свой кодировщик, а не общий `json`: общий настраивает приложение
--- (глубина, разреженные массивы), и описание причины от этого зависеть
--- не должно — тем более бросать.
local encode = json.new().encode

--- Копия значения без тайн.
---@param name any Под каким именем лежит значение
---@param value any
---@param seen table<table, boolean> Таблицы, внутри которых мы сейчас находимся
---@return any
local function cleaned(name, value, seen)
    if Module.secret(name) then
        return Module.HIDDEN
    end

    if type(value) ~= 'table' then
        return Module.scrub(value)
    end

    if seen[value] then
        return Module.CYCLE
    end

    seen[value] = true

    local copy = {}

    for key, inner in pairs(value) do
        copy[key] = cleaned(key, inner, seen)
    end

    -- Отметка снимается на выходе: кольцо — это ссылка на таблицу, внутри
    -- которой мы сейчас находимся, а не вторая ссылка на одну и ту же
    -- таблицу из соседних полей. Второе законно и прятать его нечего.
    seen[value] = nil

    return copy
end

--- Копия значения, из которой вырезаны тайны.
---
--- Именно копия: подстановки приходят ссылкой на чужую таблицу, и правка
--- на месте записала бы слово «скрыто» настоящим паролем в том, из чего
--- отказ собрали.
---@param name any Под каким именем лежит значение; nil, если имени нет
---@param value any
---@return any
function Module.clean(name, value)
    return cleaned(name, value, {})
end

--- Что напечатал `tostring`, если он дал строку.
---
--- Чужой `__tostring` вправе бросить, а в LuaJIT — и вернуть не строку.
--- Описание причины бросать не вправе: его пишут там, где поломка уже
--- случилась, и второй бросок унёс бы с собой запись о первой.
---@param value any
---@return string|nil
local function printed(value)
    local ok, said = pcall(tostring, value)

    if ok and type(said) == 'string' then
        return said
    end

    return nil
end

--- Строка, пригодная для записи: вместо невалидного UTF-8 — сколько там было.
---
--- Журнал сверяет с UTF-8 строку поля целиком и негодную заменяет целиком:
--- одно двоичное поле причины стёрло бы из записи всё описание.
---@param text string
---@return string
local function readable(text)
    if utf8.len(text) ~= nil then
        return text
    end

    return ('[не UTF-8, %d байт]'):format(#text)
end

--- Печатает ли таблица себя сама.
---
--- Метатаблица читается мимо её собственной метатаблицы: чужой `__index`
--- на ней мог бы бросить. Закрытая метатаблица (`__metatable`) таблицей
--- не бывает, и такая таблица описывается полями.
---@param value table
---@return boolean
local function printable(value)
    local meta = getmetatable(value)

    return type(meta) == 'table' and rawget(meta, '__tostring') ~= nil
end

--- Значение ядра, которое `json` пишет сам: 64-битное целое и `box.NULL`.
---
--- Прочие cdata `json` не берёт и бросает — и пустой указатель другого
--- рода тоже, хотя он равен `nil`. Их печать и так читается: uuid, decimal,
--- дата, кортеж и `box.error` печатают себя сами.
---@param value any
---@return boolean
local function exact(value)
    return ffi.istype('int64_t', value) or ffi.istype('uint64_t', value) or ffi.istype('void *', value) and value == nil
end

--- Ключ, который `json` примет.
---
--- Целое остаётся числом, пока double хранит его точно: массив должен
--- остаться массивом. Прочее — дробь, бесконечность, boolean, таблица —
--- становится своей печатью: на таком ключе `json` бросает. Решает ли
--- печать о тайне, скажет `clean`: ключ-таблица, напечатавшая `password`,
--- в описании выглядит этим именем и прячется так же.
---@param key any
---@return any
local function keyed(key)
    if type(key) == 'number' and key % 1 == 0 and math.abs(key) <= EXACT_INTEGER then
        return key
    end

    return readable(printed(key) or ('[' .. type(key) .. ']'))
end

---@class TntErrorOutline
---@field seen table<table, boolean> Таблицы, внутри которых мы сейчас находимся
---@field left integer Сколько пар ещё войдёт в описание
---@field cut boolean Вошли ли в описание не все пары

---@type fun(value: any, depth: integer, state: TntErrorOutline): any
local copied

--- Копия таблицы в пределах глубины и числа пар.
---
--- Кольцо и соседние ссылки на одну таблицу различаются так же, как
--- в `clean`: отметка снимается на выходе.
---@param value table
---@param depth integer
---@param state TntErrorOutline
---@return any
local function tabled(value, depth, state)
    if state.seen[value] then
        return Module.CYCLE
    end

    if depth > Module.DEPTH then
        return DEEP
    end

    state.seen[value] = true

    local copy = {}

    for key, inner in pairs(value) do
        if state.left < 1 then
            state.cut = true

            break
        end

        state.left = state.left - 1
        copy[keyed(key)] = copied(inner, depth + 1, state)
    end

    state.seen[value] = nil

    return copy
end

--- Копия значения, которую `json` закодирует без отказа.
---
--- Таблица без своей печати описывается полями. Таблица, чья печать
--- бросила, — тоже: поля скажут о ней больше, чем пустая отметка.
--- Всё прочее, чего `json` не пишет, — функция, userdata, чужая cdata —
--- становится своей печатью, а не сумевшее напечататься — своим родом.
---@param value any
---@param depth integer
---@param state TntErrorOutline
---@return any
copied = function(value, depth, state)
    local kind = type(value)

    if KEPT[kind] or exact(value) then
        return value
    end

    local said = nil

    if kind ~= 'table' or printable(value) then
        said = printed(value)
    end

    if said ~= nil then
        return readable(said)
    end

    if kind == 'table' then
        return tabled(value, depth, state)
    end

    return '[' .. kind .. ']'
end

--- Причина поломки одной строкой — для записи журнала и для цепочки отказа.
---
--- Строка и всё, что печатает себя само (`box.error`, отказ с `__tostring`),
--- остаются своей печатью. Простая таблица печатала бы только свой адрес —
--- `table: 0x…`, — и номер происшествия вёл бы в запись, из которой
--- не понять, что сломалось. Поэтому она описывается JSON своей копии:
--- не глубже `DEPTH` уровней, не больше `ENTRIES` пар, кольцо — отметкой.
---
--- Тайны прячутся по именам ключей до кодирования, а не после: в тексте
--- JSON имя и значение — уже просто соседние слова, и поддерево под
--- именем `password` образцы строки не узнают. Готовый текст проходит
--- ещё и `scrub`: он прячет пароль в адресе и режет строку по окну.
---@param value any
---@return string
function Module.describe(value)
    ---@type TntErrorOutline
    local state = { seen = {}, left = Module.ENTRIES, cut = false }
    local copy = copied(value, 1, state)

    if type(copy) ~= 'table' then
        return Module.scrub(tostring(copy))
    end

    local text = encode(Module.clean(nil, copy))

    if state.cut then
        text = text .. CUT
    end

    return Module.scrub(text)
end

return Module
