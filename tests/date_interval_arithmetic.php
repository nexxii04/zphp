<?php
// add() and sub() follow timelib: intervals from a duration add hours,
// minutes, and seconds as elapsed time (timelib_add_wall), diff() results and
// date-string intervals add on the wall clock (timelib_add), and date-string
// intervals keep their weekday and special parts
$zones = ['UTC', 'America/New_York', 'Europe/London', 'Australia/Lord_Howe', 'Asia/Kolkata', '+05:30', 'EST'];
$starts = [
    '2024-03-10 01:30:00', '2024-03-10 03:30:00.250000', '2024-11-03 00:30:00', '2024-11-03 01:30:00',
    '2024-03-31 00:59:59.999999', '2024-10-27 01:30:00', '2024-01-31 10:00:00', '2024-02-29 23:59:59.5',
    '1969-12-31 23:59:59.75', '2024-04-06 01:45:00',
];
$specs = ['PT1H', 'PT24H', 'P1D', 'P1M', 'P1Y2M3DT4H5M6S', 'PT90M', 'PT0S', 'P1W', 'PT36H'];
$strings = ['+1 day', '+1 hour', '+24 hours', 'next monday', 'last day of next month', '+2 weekdays', '-3 weekdays',
    '+1 week 2 days ago', 'third friday of next month', '+500 msec', '-1 usec', 'first day of', 'saturday this week'];

function show(DateTimeInterface $d): string {
    return $d->format('Y-m-d H:i:s.u T U');
}

foreach ($zones as $zone) {
    $tz = new DateTimeZone($zone);
    echo "== $zone\n";
    foreach ($starts as $s) {
        $d = new DateTimeImmutable($s, $tz);
        echo $s, "\n";
        foreach ($specs as $spec) {
            $i = new DateInterval($spec);
            $n = new DateInterval($spec);
            $n->invert = 1;
            echo '  ', $spec, ': ', show($d->add($i)), ' | ', show($d->sub($i)), ' | ', show($d->add($n)), "\n";
        }
        $f = new DateInterval('PT1S');
        $f->f = 0.75;
        echo '  f: ', show($d->add($f)), ' | ', show($d->sub($f)), "\n";
        foreach ($strings as $str) {
            $i = DateInterval::createFromDateString($str);
            echo '  ', $str, ': ', show($d->add($i));
            try {
                echo ' | ', show($d->sub($i));
            } catch (DateInvalidOperationException $e) {
                echo ' | ', $e->getMessage();
            }
            echo "\n";
        }
        foreach (['2024-03-10 12:00:00', '2024-11-03 12:00:00.5', '2023-01-15 08:00:00'] as $other) {
            $o = new DateTimeImmutable($other, $tz);
            $diff = $d->diff($o);
            echo '  diff ', $other, ': ', show($d->add($diff)), ' | ', show($o->sub($diff)), "\n";
        }
        $m = new DateTime($s, $tz);
        date_add($m, new DateInterval('PT2H'));
        date_sub($m, DateInterval::createFromDateString('+1 day'));
        echo '  procedural: ', show($m), "\n";
    }
}

foreach (['next monday', '+1 day', 'last day of next month', 'third friday of next month', '+3 weekdays', '+1 week 2 days ago', 'tomorrow', '-1 usec'] as $str) {
    $i = DateInterval::createFromDateString($str);
    echo json_encode($str), ': ', json_encode([$i->y, $i->m, $i->d, $i->h, $i->i, $i->s, $i->f, $i->invert, $i->days]), "\n";
}
foreach (['2024-01-01', 'garbage', '', 'yesterday noon', '+1.5 hours', '@5', 'EST', '10:00'] as $str) {
    try {
        DateInterval::createFromDateString($str);
        echo json_encode($str), ": ok\n";
    } catch (DateMalformedIntervalStringException $e) {
        echo json_encode($str), ': ', $e->getMessage(), "\n";
    }
    var_dump(@date_interval_create_from_date_string($str));
}

// a period steps with the whole interval and keeps microseconds and the
// start's class
class MyDate extends DateTimeImmutable {}
$p = new DatePeriod(new MyDate('2024-03-09 02:30:00.5', new DateTimeZone('America/New_York')), new DateInterval('PT12H'), 4);
foreach ($p as $k => $d) echo $k, ' ', get_class($d), ' ', show($d), "\n";
$p = new DatePeriod(new DateTime('2024-01-31'), DateInterval::createFromDateString('last day of next month'), 3);
foreach ($p as $d) echo show($d), "\n";
