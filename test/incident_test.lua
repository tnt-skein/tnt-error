--- Тесты опознавателя происшествия: вид, азбука, случайность.

local t = require('luatest')

local helper = dofile('test/helper.lua')

local g = helper.group('tnt.error.incident')

--- Модуль опознавателей, загруженный группой.
---@return any
local function incident()
    return helper.part('tnt.error.incident')
end

--- Опознаватель, собранный из заданных байтов.
---@param bytes integer[]
---@return string
local function from(bytes)
    local given = {}

    for _, byte in ipairs(bytes) do
        table.insert(given, string.char(byte))
    end

    incident()._set_source({
        random = function()
            return table.concat(given)
        end,
    })

    return incident().next()
end

g.test_identifier_is_two_groups_of_four_letters = function()
    t.assert_equals(incident().next(), helper.INCIDENT)
    t.assert_equals(#helper.INCIDENT, incident().LENGTH + 1)
end

g.test_every_byte_becomes_its_letter_of_the_alphabet = function()
    -- Байты 0, 1, 2 ... подряд дают первые буквы азбуки подряд: так видно,
    -- что байт не теряется и не сдвигается.
    t.assert_equals(from({ 0, 1, 2, 3, 4, 5, 6, 7 }), '0123-4567')
    t.assert_equals(from({ 26, 27, 28, 29, 30, 31, 10, 11 }), 'TVWX-YZAB')
end

g.test_a_byte_above_the_alphabet_wraps_around_without_a_gap = function()
    -- Байтов 256, букв 32, и на каждую букву приходится ровно восемь
    -- значений байта: перекоса нет, а значит, нет и подсказки о том,
    -- какой байт выпал.
    t.assert_equals(from({ 32, 33, 64, 255, 0, 0, 0, 0 }), '010Z-0000')
end

g.test_alphabet_has_no_letters_that_sound_alike = function()
    -- I, L, O и U выброшены: первые три неотличимы от единицы и нуля
    -- в трубке, последняя выброшена, чтобы из случайных букв не сложилось
    -- бранное слово.
    for _, letter in ipairs({ 'I', 'L', 'O', 'U' }) do
        t.assert_equals(incident().ALPHABET:find(letter, 1, true), nil)
    end

    t.assert_equals(#incident().ALPHABET, 32)
end

g.test_the_alphabet_is_the_one_ulid_is_written_with = function()
    -- Одна азбука на репозиторий: второй список тех же знаков однажды
    -- разошёлся бы с первым.
    t.assert_equals(incident().ALPHABET, helper.part('tnt.id.crockford').ALPHABET)
end

g.test_real_randomness_gives_a_readable_identifier = function()
    -- Без подмены: умолчание берёт случайность у ядра, и проверить надо
    -- именно его — подменённое средство ничего не говорит о настоящем.
    incident()._set_source(nil)

    local first = incident().next()
    local second = incident().next()

    t.assert_str_matches(first, '[%u%d][%u%d][%u%d][%u%d]%-[%u%d][%u%d][%u%d][%u%d]')
    t.assert_not_equals(first, second)
end
