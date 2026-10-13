<?php

// Prints the site's Kirby roots as JSON: php roots.php <index.php>
require __DIR__ . '/boot.php';

kirby_orb_boot(realpath($argv[1]), function ($kirby) {
	$roots = [];
	foreach (['index', 'kirby', 'site', 'content', 'accounts', 'plugins'] as $name) {
		$roots[$name] = $kirby->root($name);
	}
	echo json_encode($roots, JSON_UNESCAPED_SLASHES) . "\n";
});
