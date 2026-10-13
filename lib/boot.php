<?php

// Starts the Kirby site behind the given index.php and hands the app to $then. The page the
// index renders is discarded; $then runs at shutdown so it also works when the index exits.
function kirby_orb_boot($index, $then)
{
	$_SERVER['REQUEST_URI'] = '/__kirby-orb';
	$_SERVER['HTTP_HOST'] = $_SERVER['SERVER_NAME'] = 'localhost';

	register_shutdown_function(function () use ($then) {
		while (ob_get_level() > 0) {
			ob_end_clean();
		}
		$kirby = class_exists('Kirby\Cms\App') ? Kirby\Cms\App::instance(null, true) : null;
		if ($kirby === null) {
			fwrite(STDERR, "Kirby did not start\n");
			exit(1);
		}
		$then($kirby);
	});

	ob_start();
	chdir(dirname($index));
	require $index;
}
