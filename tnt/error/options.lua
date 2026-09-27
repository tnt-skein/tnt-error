--- Настройки каталога отказов: чем отвечать и что показывать.
---
--- Отдельно от фасада, потому что растут они врозь. Фасад — это восемь
--- вызовов, которыми отказ заводят, накрывают и показывают, и их число
--- не меняется годами. Настройки же прибывают вместе с тем, что каталог
--- умеет показать: вид тела, подпись ответа, страница человеку, разбор
--- поломки разработчику.
---
--- Ошибка в настройках — исключение, а не отказ: их пишут кодом, и
--- обнаружиться опечатка обязана при запуске узла, а не в ответе клиенту.

local render = require('tnt.error.render')
local validate = require('tnt.validate')

local Module = {}

--- Умолчания.
Module.DEFAULTS = {
    -- RFC 9457, а не простой вид: у отказа появляется опознаваемый род,
    -- и клиенту не приходится разбирать текст сообщения.
    view = 'problem',
    -- URN, а не адрес: выдумывать за приложение его домен нельзя,
    -- а несуществующий адрес в ответе выглядит как обещание страницы
    -- с объяснением, которой нет. URN честно говорит «это имя, не адрес».
    type_base = 'urn:tnt-error:',
    instance_base = 'urn:tnt-incident:',
    -- Страница — встроенная, и она уходит только тому, кто её просит
    -- заголовком `Accept`. Выключать её нечему: клиент, разбирающий тело,
    -- страницы не просит и не получает.
    page = true,
    -- Разбор поломки выключен: место в коде, стек и заголовки запроса
    -- наружу не показываются, пока об этом не сказали вслух.
    debug = false,
}

--- Вид ответа: имя готового либо своя функция, собирающая тело.
---@alias TntErrorView string|fun(err: TntError, settings: TntErrorSettings): table

--- Страница отказа: `true` — встроенная, `false` — не отвечать страницей
--- вовсе, функция — своя разметка по данным страницы.
---@alias TntErrorPage boolean|fun(shown: TntErrorPageView): string|nil

--- Перевод слова отказа: слово на языке запроса и сам язык; пустота —
--- слово каталога остаётся (`tnt.error.translation`).
---@alias TntErrorTranslate fun(err: TntError, request: any): (string|nil, string|nil)

--- Что можно задать настройкой. Все поля необязательны: у каждого есть
--- умолчание, и требовать их значило бы заставлять приложение повторять
--- то, что пакет проставит сам.
---@class TntErrorOptions
---@field view TntErrorView|nil Вид ответа: problem, simple либо своя функция
---@field content_type string|nil Чем подписан ответ; по умолчанию — подпись вида
---@field type_base string|nil Чем начинается URI рода отказа
---@field instance_base string|nil Чем начинается URI происшествия
---@field page TntErrorPage|nil Страница браузеру: встроенная, своя либо никакой
---@field debug boolean|nil Показывать ли разбор поломки на странице
---@field translate TntErrorTranslate|nil Слово на языке запроса; без неё — слово каталога

--- Настройки после проверки: здесь заполнено всё, кроме перевода —
--- у него умолчания нет, и без него слово уходит, как объявлено.
---@class TntErrorSettings
---@field view TntErrorView Вид ответа
---@field content_type string Чем подписан ответ
---@field type_base string Чем начинается URI рода отказа
---@field instance_base string Чем начинается URI происшествия
---@field page TntErrorPage Страница браузеру
---@field debug boolean Показывать ли разбор поломки на странице
---@field translate TntErrorTranslate|nil Слово на языке запроса

--- Чего ждут от настройки вида.
---
--- Имена готовых видов берутся у представления: перечислить их здесь
--- второй раз значило бы однажды добавить вид, о котором проверка
--- настроек не знает, — и получить отказ на законном имени.
local VIEW_EXPECTATION = ("одним из: '%s' либо своей функцией"):format(
    table.concat(render.NAMES, "', '")
)

--- Схема настроек.
local OPTIONS = {
    view = validate.rule({
        name = 'вид ответа',
        title = 'вид ответа',
        gender = 'm',
        default = Module.DEFAULTS.view,
        check = function(value, node)
            -- Своя функция и имя готового вида проверяются порознь:
            -- сводить их к одной проверке нечем, да и незачем.
            if type(value) == 'function' or render.knows(value) then
                return value
            end

            return nil, node:must_be(VIEW_EXPECTATION, value)
        end,
    }),
    content_type = validate.string({
        min = 1,
        optional = true,
        title = 'подпись ответа',
        gender = 'f',
    }),
    type_base = validate.string({
        default = Module.DEFAULTS.type_base,
        title = 'начало URI рода отказа',
        gender = 'n',
    }),
    instance_base = validate.string({
        default = Module.DEFAULTS.instance_base,
        title = 'начало URI происшествия',
        gender = 'n',
    }),
    page = validate.rule({
        name = 'страница отказа',
        title = 'страница отказа',
        gender = 'f',
        default = Module.DEFAULTS.page,
        check = function(value, node)
            if type(value) == 'boolean' or type(value) == 'function' then
                return value
            end

            return nil, node:must_be('true, false либо своей функцией', value)
        end,
    }),
    debug = validate.boolean({
        default = Module.DEFAULTS.debug,
        title = 'разбор поломки на странице',
        gender = 'm',
    }),
    -- Переводчика пакет не знает и знать не должен: функцию приносит тот,
    -- кто собирает приложение, и связывает ею отказы с переводами сам.
    translate = validate.rule({
        name = 'перевод слова отказа',
        title = 'перевод слова отказа',
        gender = 'm',
        optional = true,
        check = function(value, node)
            if type(value) ~= 'function' then
                return nil, node:must_be('функцией от отказа и запроса', value)
            end

            return value
        end,
    }),
}

--- Проверенные настройки.
---
--- Заданное перекрывает умолчание целиком, а не по полю: настройка
--- вызывается один раз при запуске, и «что-то осталось от прошлого раза»
--- здесь только запутывало бы.
---@param opts TntErrorOptions|nil
---@return TntErrorSettings
function Module.checked(opts)
    local settings, refusal = validate.settings(opts or {}, OPTIONS)

    if refusal ~= nil then
        error(('настройки отказов непригодны: %s'):format(refusal))
    end

    -- Подпись ответа не задаётся сама по себе: она следует за видом,
    -- и заданная отдельно нужна только тому, кто собирает тело своей
    -- функцией.
    settings.content_type = settings.content_type or render.content_type_of(settings.view)

    return settings
end

return Module
