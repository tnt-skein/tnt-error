--- Каталог отказов: код, статус ответа и строка для человека.
---
--- Отказ объявляется один раз и в одном месте, а не сочиняется там, где
--- случился. Иначе один и тот же «нет такого клиента» выходит наружу
--- тремя разными строками с тремя разными статусами, и клиент, который
--- хотел бы отличать отказы друг от друга, вынужден разбирать текст.
---
--- Строка пишется по-русски прямо здесь, но берётся по коду, а не
--- склеивается по месту. На этом держится перевод: коду и подстановкам
--- хватает, чтобы выдать ту же строку по-английски (настройка
--- `translate`, `tnt.error.translation`). Склеенная по месту строка
--- не переводится вовсе.
---
--- Подстановки двух видов, и оба нужны. Именные — `{id}` — берутся
--- из таблицы по имени: порядок ключей в Lua не определён, и именно они
--- переживут перевод, где слова в предложении встанут иначе. По порядку —
--- `%s` — берутся из списка: так короче там, где подстановка одна.
---
--- Повторное объявление занятого кода — отказ. Каталог общий на всё
--- приложение, и два пакета, назвавшие своё одинаково, иначе узнают
--- об этом в тот день, когда клиент получит на свой запрос чужой текст.
---
--- Заменить чужое объявление своим всё же можно — но другим вызовом,
--- `redefine`. Слово пакета пишется для всех, а приложение говорит
--- со своим человеком своими словами, и запрещать ему это значит
--- заставлять заводить рядом второй код о том же самом. Разница
--- с `define` только в одном: замена сказана вслух, а не случилась
--- по недосмотру.
---
--- Внутренняя поломка объявлена здесь же и в каждом каталоге с самого
--- начала: без неё нечем ответить на первую же панику. Здесь же стоит
--- и правило про `{incident}` в её слове — у самих данных, а не этажом
--- выше: каталог открыт полем реестра, и проверка, стоящая только
--- в реестре, обходится одним обращением напрямую.

local validate = require('tnt.validate')

local Module = {}

--- Код внутренней поломки.
Module.INTERNAL = 'internal'

--- Объявление внутренней поломки.
---
--- Строка нарочно не говорит ничего о причине: причина лежит в журнале,
--- а здесь остаётся только то, что человек может сделать — назвать номер.
local INTERNAL_DECLARATION = {
    status = 500,
    title = 'Внутренняя ошибка',
    message = 'Внутренняя ошибка. Назовите происшествие {incident} тому, '
        .. 'кто будет разбираться.',
}

--- Подстановка, которой слово внутренней поломки называет опознаватель.
local INCIDENT_MARK = '{incident}'

--- Что встаёт на место подстановки, когда её ищут.
---
--- Годится что угодно, кроме самой подстановки: важно только, изменится
--- строка или нет.
local INCIDENT_PROBE = { incident = '—' }

---@class TntErrorDeclaration
---@field status integer Статус ответа HTTP
---@field message string Строка для человека, с подстановками или без
---@field title string|nil Краткое имя рода отказа; по умолчанию — сам шаблон
---@field type string|nil URI рода отказа; по умолчанию собирается из кода

--- Схема объявления. Ошибка в ней — исключение, а не отказ: объявление
--- пишется кодом и обязано обнаружиться при загрузке модуля.
local DECLARATION = {
    status = validate.integer({
        min = 100,
        max = 599,
        title = 'статус ответа',
        gender = 'm',
    }),
    message = validate.string({ min = 1, title = 'строка для человека', gender = 'f' }),
    title = validate.string({
        min = 1,
        optional = true,
        title = 'имя рода отказа',
        gender = 'n',
    }),
    type = validate.string({ min = 1, optional = true, title = 'URI рода отказа', gender = 'm' }),
}

--- Из чего состоит код: строчные латинские буквы, цифры и подчёркивание,
--- части разделяются точкой — `customer.not_found`.
---
--- Заглавных и кириллицы в коде нет нарочно: код читает машина, а не
--- человек, он попадает в URI рода отказа и в ответ клиенту, и там
--- разница регистра однажды разводит `Customer` и `customer` по разным
--- ветвям.
local SEGMENT = '^%l[%l%d_]*$'

--- Годится ли значение в код отказа.
---
--- Спрашивается только при объявлении: какой вид у кода, решает каталог,
--- а не тот, кто смотрит на строку со стороны. Догадок «код это или слово
--- для человека» в пакете нет нигде — из-за такой догадки чужое `timeout`
--- однажды пошло искать себя в каталоге и уронило узел.
---@param value any
---@return boolean
function Module.is_code(value)
    if type(value) ~= 'string' or value == '' then
        return false
    end

    -- Точка дописывается, чтобы последняя часть тоже попала в обход:
    -- образец ищет часть вместе с точкой за ней.
    for part in (value .. '.'):gmatch('([^%.]*)%.') do
        if part:match(SEGMENT) == nil then
            return false
        end
    end

    return true
end

--- Подставляет значения в шаблон строки.
---
--- Подстановка, для которой нечего подставить, остаётся в строке как
--- есть — и это лучше, чем пустое место: `Клиента №{id} нет` сразу
--- говорит, что забыли передать `id`, а `Клиента № нет` выглядит
--- законченной фразой и доживает до продакшена.
---@param template string
---@param params table
---@return string
function Module.fill(template, params)
    -- Имя подстановки начинается с буквы или цифры: пустые фигурные
    -- скобки — это просто скобки, и подставлять в них нечего.
    local named = template:gsub('{(%w[%w_]*)}', function(name)
        local value = params[name]

        if value == nil then
            return nil
        end

        return tostring(value)
    end)

    local at = 0

    return (
        named:gsub('%%s', function()
            at = at + 1

            local value = params[at]

            if value == nil then
                return nil
            end

            return tostring(value)
        end)
    )
end

---@class TntErrorCatalog
---@field declarations table<string, TntErrorDeclaration> Объявления по кодам
local Catalog = {}
Catalog.__index = Catalog

--- Забыто ли в слове внутренней поломки название опознавателя.
---
--- Опознаватель и есть весь ответ при 500: остальное в нём — общая
--- фраза, одинаковая для всех поломок. Своё слово сказать можно, но
--- не ценой номера, по которому происшествие находят в журнале.
---
--- Ищется не подстрока, а подстановка: важно не то, что `{incident}`
--- где-то написано, а то, что на его место что-то встанет — и спрошено
--- это у той же `fill`, которой слово собирается на самом деле.
---@param declaration any
---@return boolean
local function forgets_incident(declaration)
    local said = type(declaration) == 'table' and declaration.message

    -- Слово не той породы здесь не разбирается: его отвергнет проверка
    -- объявления, и сказать об этом она умеет точнее. Одним выражением,
    -- а не ранним `return false`: ответ идёт только в условие, и там
    -- ложь от пустоты не отличить — поломку ветки не заметил бы никто.
    return type(said) == 'string' and Module.fill(said, INCIDENT_PROBE) == said
end

--- Проверяет объявление и кладёт его в каталог.
---
--- Занят код или свободен, здесь не спрашивается: на это у объявления
--- и переопределения ответы прямо противоположные, и каждое отвечает
--- за себя само.
---@param self TntErrorCatalog
---@param code any
---@param declaration TntErrorDeclaration|nil
---@return string code
local function store(self, code, declaration)
    if not Module.is_code(code) then
        error(
            ('код отказа %s непригоден: ждали вид customer.not_found'):format(tostring(code))
        )
    end

    local checked, refusal = validate.settings(declaration or {}, DECLARATION)

    if refusal ~= nil then
        error(('объявление отказа %s непригодно: %s'):format(code, refusal))
    end

    -- Шаблон становится именем рода отказа, если своего имени не дали:
    -- имя обязано быть одним и тем же от случая к случаю, а шаблон
    -- как раз таков — подстановки в нём ещё не сделаны.
    checked.title = checked.title or checked.message

    self.declarations[code] = checked

    return code
end

--- Каталог, в котором объявлена одна внутренняя поломка.
---
--- Объявляется сразу, а не при первой панике: паника — не то место,
--- где стоит выяснять, есть ли чем на неё ответить.
---@return TntErrorCatalog
function Module.new()
    local self = setmetatable({ declarations = {} }, Catalog)

    store(self, Module.INTERNAL, INTERNAL_DECLARATION)

    return self
end

--- Объявляет отказ.
---@param code string Код вида `customer.not_found`
---@param declaration TntErrorDeclaration
---@return string code Тот же код: его удобно сохранить в переменную
function Catalog:define(code, declaration)
    if self.declarations[code] ~= nil then
        error(
            ('отказ %s уже объявлен: два объявления одного кода расходятся'):format(
                code
            )
        )
    end

    return store(self, code, declaration)
end

--- Меняет объявление уже объявленного отказа.
---
--- Отдельный вызов, а не `define` поверх занятого кода: два объявления
--- одного кода, случившиеся по недосмотру, расходятся молча, и ловить
--- их нужно по-прежнему. А приложение, которому не годится слово пакета,
--- говорит об этом вслух — и тогда замена законна.
---
--- Свободный код переопределять нечего: так ловится опечатка в коде,
--- которая иначе завела бы рядом второй, никем не используемый отказ.
---@param code string
---@param declaration TntErrorDeclaration
---@return string code
function Catalog:redefine(code, declaration)
    if self.declarations[code] == nil then
        error(('отказ %s не объявлен: переопределять нечего'):format(tostring(code)))
    end

    if code == Module.INTERNAL and forgets_incident(declaration) then
        error(
            'слово внутренней поломки обязано называть '
                .. INCIDENT_MARK
                .. ': без него человеку нечего сказать дежурному, а дежурному — нечего искать'
        )
    end

    return store(self, code, declaration)
end

--- Объявление отказа либо nil.
---@param code any
---@return TntErrorDeclaration|nil
function Catalog:find(code)
    if type(code) ~= 'string' then
        return nil
    end

    return self.declarations[code]
end

--- Все объявленные коды по алфавиту.
---@return string[]
function Catalog:codes()
    local known = {}

    for code in pairs(self.declarations) do
        table.insert(known, code)
    end

    table.sort(known)

    return known
end

return Module
