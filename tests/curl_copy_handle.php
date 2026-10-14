<?php
// curl_copy_handle keeps the url and options, and the copy outlives the
// original with its own header list. urls are already normalized, since
// libcurl 8.23 adds the trailing slash before a transfer and older ones don't
$ch = curl_init('http://example.com/');
echo curl_getinfo($ch, CURLINFO_EFFECTIVE_URL), '|', curl_getinfo($ch)['url'], "\n";
curl_setopt($ch, CURLOPT_URL, 'http://test.com/');
echo curl_getinfo($ch, CURLINFO_EFFECTIVE_URL), "\n";
echo curl_getinfo(curl_copy_handle($ch), CURLINFO_EFFECTIVE_URL), "\n";
curl_reset($ch);
var_dump(curl_getinfo($ch, CURLINFO_EFFECTIVE_URL));

$file = tempnam(sys_get_temp_dir(), 'zc');
file_put_contents($file, 'hello');
$url = 'file://' . (DIRECTORY_SEPARATOR === '\\' ? '/' . str_replace('\\', '/', $file) : $file);
$h = curl_init($url);
curl_setopt_array($h, [CURLOPT_HTTPHEADER => ['X-A: 1'], CURLOPT_RETURNTRANSFER => true]);
$h2 = curl_copy_handle($h);
curl_close($h);
unset($h);
echo get_class($h2), ' ', curl_getinfo($h2, CURLINFO_EFFECTIVE_URL) === $url ? 'same url' : 'other url', ' ', curl_exec($h2), "\n";
var_dump(curl_copy_handle($h2) instanceof CurlHandle);
unlink($file);
