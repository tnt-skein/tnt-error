--- Слово отказа на языке запроса.
---
--- Каталог пишет слово по-русски прямо в объявлении и берёт его по коду,
--- а не склеивает по месту: коду и подстановкам хватает, чтобы выдать
--- то же слово на другом языке. Переводчика пакет не знает — он приходит
--- настройкой `translate`: функция от отказа и запроса отдаёт слово
--- на языке запроса и сам язык. Так пакет отказов не начинает зависеть
--- от пакета переводов, а связывает их тот, кто собирает приложение.
---
--- Запрос функция получает вторым аргументом не зря. Отказ парой
--- `nil, err` проходит слой языка насквозь, и рисуют его уже снаружи,
--- где контекста с языком нет, — а в самом запросе язык остаётся.
---
--- Переводится только слово — то, что сказано об этом случае. Своё слово
--- `explain` не переводится вовсе: его написал разработчик для этого
--- случая, и строка по коду сказала бы меньше — даже на языке
--- по умолчанию. Сорвавшийся перевод человека без ответа не оставляет:
--- уходит слово каталога, а в журнал ложится запись — опечатка в строках
--- перевода иначе жила бы незамеченной до первой жалобы.

local failure = require('tnt.error.failure')
local secret = require('tnt.error.secret')
local catalog = require('tnt.error.catalog')

local Module = {}

--- Заголовки ответа, которые ставит перевод.
Module.CONTENT_LANGUAGE = 'content-language'
Module.VARY = 'vary'

--- Как заголовок запроса о языке называется в `Vary` (RFC 9110, §12.5.4).
Module.VARY_BY = 'Accept-Language'

--- Сорвавшийся перевод пишется туда же, куда и поломки пакета: дежурный
--- ищет записи отказов по одному имени.
local log = require('tnt.log').new('tnt.error')

--- Почему перевод не взят, либо nil.
---
--- Опознаватель — весь ответ при внутренней поломке, и слово без него
--- оставило бы человеку одну общую фразу, а дежурному — нечего искать.
--- Каталог держит то же правило у объявления (`catalog.redefine`), но
--- строки перевода ему не видны: их сверяют здесь, уже подставленными.
---@param shown TntError
---@param word any
---@return string|nil
local function unfit(shown, word)
    if type(word) ~= 'string' then
        return ('перевод отдал %s, а не строку'):format(type(word))
    end

    -- Начало поиска не написано числом: у `find(s, 1, true)` мутант `0`
    -- неотличим — ноль библиотека читает как единицу.
    if shown.code == catalog.INTERNAL and shown.incident ~= nil and word:find(shown.incident, nil, true) == nil then
        return ('слово внутренней поломки не называет происшествие %s'):format(
            shown.incident
        )
    end

    return nil
end

--- Отказ со словом на языке запроса и язык этого слова.
---
--- Отказ копируется, а не правится: тот же отказ рисуют и другому
--- запросу на другом языке, и пишут в журнал, где слово нужно прежнее.
--- Слово проходит вырезание тайн, как и слово `explain`: его сложила
--- чужая функция, и что она подставила, отсюда не видно.
---@param shown TntError
---@param request any
---@param settings TntErrorSettings
---@return TntError shown
---@return string|nil language
function Module.of(shown, request, settings)
    local translate = settings.translate

    if translate == nil or shown.explained then
        return shown, nil
    end

    local ok, word, language = pcall(translate, shown, request)

    -- Пустота — не беда: строки на этот код у приложения просто нет,
    -- и запись о ней на каждый промах по адресу засорила бы журнал.
    if ok and word == nil then
        return shown, nil
    end

    local why

    if ok then
        why = unfit(shown, word)
    else
        why = tostring(word)
    end

    if why ~= nil then
        log.warn('слово отказа не переведено', { code = shown.code, reason = why })

        return shown, nil
    end

    local told = {}

    for name, value in pairs(shown) do
        told[name] = value
    end

    told.message = secret.scrub(word)

    return failure.new(told), type(language) == 'string' and language or nil
end

--- `Vary` с заголовком языка.
---
--- Звёздочка уже говорит «по всему», а названный заголовок второй раз
--- не пишется. Значение не строкой дописать некуда, и оно остаётся.
---@param vary any
---@return any
local function varied(vary)
    if type(vary) ~= 'string' then
        return vary == nil and Module.VARY_BY or vary
    end

    -- Запятые по краям — чтобы имя сверялось целиком, а не частью соседнего.
    local named = ',' .. vary:lower():gsub('%s', '') .. ','

    if named:find(',accept-language,', nil, true) or named:find(',*,', nil, true) then
        return vary
    end

    return vary .. ', ' .. Module.VARY_BY
end

--- Ставит ответу язык слова и `Vary`.
---
--- `Vary` получает всякий ответ каталога с переводом, а не только
--- переведённый: слово выбирает язык запроса, и кэш обязан хранить ответ
--- по языку и тогда, когда на этом языке слова не нашлось, — иначе
--- посетитель, для которого перевод есть, получит сохранённое слово
--- другого. Язык же называется только у переведённого слова: слово
--- каталога написано на своём языке, и чужой `Content-Language` у него
--- был бы неправдой. Язык, названный самим отказом, остаётся.
---@param headers table<string, any>
---@param settings TntErrorSettings
---@param language string|nil
function Module.annotate(headers, settings, language)
    if settings.translate == nil then
        return
    end

    if language ~= nil and headers[Module.CONTENT_LANGUAGE] == nil then
        headers[Module.CONTENT_LANGUAGE] = language
    end

    headers[Module.VARY] = varied(headers[Module.VARY])
end

return Module
