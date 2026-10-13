<?php

require __DIR__ . '/boot.php';

kirby_orb_boot(realpath($argv[1]), function ($kirby) {
	$email = 'agent@orb.test';
	$password = bin2hex(random_bytes(12));
	$kirby->impersonate('kirby', function () use ($kirby, $email, $password) {
		if ($user = $kirby->user($email)) {
			$user->changePassword($password);
		} else {
			Kirby\Cms\User::create(['email' => $email, 'name' => 'Orb agent', 'role' => 'admin', 'password' => $password]);
		}
	});
	echo "email: $email\npassword: $password\n";
});
