<?php

Kirby\Cms\App::plugin('kirby-orb/login', [
	'hooks' => [
		'route:before' => function ($route, $path, $method) {
			if (
				$method === 'GET' &&
				getenv('AMP_THREAD_ID') &&
				kirby()->request()->header('x-amp-user-id') &&
				($path === 'panel' || strpos($path, 'panel/') === 0) &&
				($path === 'panel/installation' || kirby()->user() === null)
			) {
				go('__orb/login');
			}
		},
	],
	'routes' => [[
		'pattern' => '__orb/login',
		'method' => 'GET',
		'action' => function () {
			$kirby = kirby();
			$request = $kirby->request();
			$claims = array_map('trim', explode(',', (string)$request->header('x-amp-authenticated')));
			$ampUser = $request->header('x-amp-user-id');
			if (
				!getenv('AMP_THREAD_ID') || !$ampUser ||
				!in_array('amp-user=yes', $claims, true) ||
				(!in_array('collaborator=yes', $claims, true) && !in_array('workspace-member=yes', $claims, true))
			) {
				return new Kirby\Http\Response('Amp portal sign-in required', 'text/plain', 403);
			}

			$email = hash('sha256', $ampUser) . '@orb.test';
			$user = $kirby->user($email) ?? $kirby->impersonate('kirby', function () use ($email) {
				return Kirby\Cms\User::create([
					'email' => $email,
					'name' => 'Orb developer',
					'role' => 'admin',
					'password' => bin2hex(random_bytes(32)),
				]);
			});
			$user->loginPasswordless();
			return go('panel');
		},
	]],
]);
