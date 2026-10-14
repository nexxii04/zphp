<?php
// createFromFormat() and date_parse_from_format() through the timelib port:
// specifiers, separators, resets, zones, errors, and warnings
date_default_timezone_set('America/New_York');
$cases = [
  ['Y-m-d', '2024-03-15'], ['!Y-m-d', '2024-03-15'], ['Y-m-d|', '2024-03-15'], ['U.u', '1700000000.123456'],
  ['U', '1700000000'], ['!d/m/Y H:i:s', '15/03/2024 10:11:12'], ['!Y-m-d H:i:s P', '2024-03-15 10:11:12 +05:30'],
  ['!Y-m-d e', '2024-03-15 Europe/Paris'], ['!Y-m-d T', '2024-03-15 EST'], ['!Y-m-d T', '2024-03-15 CEST'],
  ['!D, d M Y', 'Fri, 15 Mar 2024'], ['!l jS F Y', 'Monday 1st January 2024'], ['!Y z', '2024 59'], ['!z Y', '59 2024'],
  ['!h:i a', '12:30 am'], ['!g:i A', '1:05 P.M.'], ['!H:i', '25:61'], ['!Y-m-d', '2024-02-30'], ['!Y-m-d', '2024-3-5 extra'],
  ['!Y-m-d+', '2024-03-15 extra'], ['!Y-m-d H', '2024-03-15'], ['!y', '69'], ['!y', '70'], ['!Y', '12345'], ['!X', '-12345'],
  ['!x', '+002024'], ['!Y#m#d', '2024/03.15'], ['!Y#m#d', '2024 03 15'], ['!Y?m?d', '2024x03y15'], ['!Y*m', '2024abc03'],
  ['!\Y Y', 'Y 2024'], ['!\\', ''], ['', ''], ['!', ''], ['Y', ''], ['!Y-m-d v', '2024-03-15 12'], ['!Y-m-d u', '2024-03-15 1'],
  ['!Y-m-d u', '2024-03-15 1234567'], ['!H:i:s.u', '10:11:12.5'], ['!i', '5'], ['!s', '5'], ['!Y-m-d O', '2024-03-15 Mars/Base'],
  ['Y-m-d !', '2024-03-15 '], ['!Y-m-d|', '2024-03-15'], ['!d', 'ab'], ['!a', 'pm'], ['!H a', '13 pm'], ['!G', '7'],
  ['!U', '-86400'], ['!U', 'abc'], ['U', '99999999999999999999999'], ['!Y-m-d\TH:i:sP', '2024-03-15T10:11:12Z'],
  ['!D', 'week'], ['!D Y-m-d', 'Mon 2024-03-15'], ['!M', 'sept'], ['!F', 'Febr'], ['!Y-m-d S', '2024-03-15 th'],
  ['!Y-m-d e', '2024-03-15 (UTC)'], ['!Y-m-d e', '2024-03-15 GMT+3'], ['!Y-m-d p', '2024-03-15 Z'],
  ['Y-m-d H:i:s', '2024-11-03 01:30:00'], ['!d.m.y', '31.12.99'], ['!n/j/y', '1/2/03'],
];
foreach ($cases as [$f, $s]) {
    echo json_encode([$f, $s]), "\n";
    $p = date_parse_from_format($f, $s);
    echo '  parse: ', json_encode($p), "\n";
    $d = DateTime::createFromFormat($f, $s, str_contains($f, 'e') ? null : new DateTimeZone('Asia/Tokyo'));
    $has_reset = str_contains($f, '!') || str_contains($f, '|') || str_contains($f, 'U');
    echo '  create: ', $d === false ? 'false' : $d->format($has_reset ? 'Y-m-d H:i:s.u T e' : 'T e'), ' ', json_encode(DateTime::getLastErrors()), "\n";
    $i = date_create_immutable_from_format($f, $s);
    echo '  immutable: ', $i === false ? 'false' : $i->format($has_reset ? 'Y-m-d H:i:s.u T e U' : 'T e'), "\n";
}

// Z_PARAM_PATH arguments reject nul bytes
$calls = [
    fn() => DateTime::createFromFormat('Y', "2024\0"),
    fn() => DateTimeImmutable::createFromFormat('Y', "2024\0"),
    fn() => date_create_from_format('Y', "2024\0"),
    fn() => date_create_immutable_from_format('Y', "2024\0"),
    fn() => date_parse_from_format('Y', "2024\0"),
    fn() => new DateTimeZone("UTC\0x"),
    fn() => timezone_open("UTC\0x"),
];
foreach ($calls as $c) {
    try {
        $c();
    } catch (ValueError $e) {
        echo $e->getMessage(), "\n";
    }
}
// a nul in the format ends it
echo json_encode(date_parse_from_format("Y\0m", '2024')), "\n";

// years far from now format without overflowing
foreach (['@-9223372036854775807', '@9223372036854775807', '@-6338724994017237208', '-200866196832-01-01', '+28345678036-02-23'] as $s) {
    echo (new DateTimeImmutable($s))->format('U | Y | o W | X | x | c'), "\n";
}
