<?php
class PGTableGrouper {
	private $inner;
	private $groups;
	private $dependencies = []; // dependent group => array of dependency groups
	private $seededDependencies = []; // type\0name => array of type\0name (external dep: name incl namespace)
	private $writtenGroups;
	private $writtenItems;
	private $skippedObjects;
	private $processing = [];

	/* seeded dependencies are currently only used for views, where it would be
	 * difficult to parse the SQL query and find the dependencies */

	const MISC_GROUP  = "_misc";
	const CROSS_GROUP = "_cross";

	public function __construct(PGDumpReaderWriter $inner,
								$skippedObjects,
								$seededDependencies = [])
	{
		$this->inner = $inner;
		$this->skippedObjects = $skippedObjects ?: [];
		$this->seededDependencies = $seededDependencies;
	}
	private function writeItem($groupName, $basePath, $load_stream) {
		if (key_exists($groupName, $this->writtenGroups)) {
			return;
		}
		if (key_exists($groupName, $this->processing)) {
			print_r($this->dependencies);
			print_r($this->processing);
			fprintf(STDERR, "Circular dependency; see output above\n");
			exit(1);
		}

		$this->processing[$groupName] = true;

		if (key_exists($groupName, $this->dependencies)) {
			foreach ($this->dependencies[$groupName] as $dependency) {
				if (!key_exists($dependency, $this->groups)) {
					throw new Exception("Group $groupName depends on bogus group $dependency");
				}
				$this->writeItem($dependency, $basePath, $load_stream);
			}
		}

		unset($this->processing[$groupName]);

		$sqlFile = "$basePath/$groupName.sql";
		$f = function() use ($sqlFile) {
			static $stream = null;
			if ($stream === null) {
				if (!is_dir(dirname($sqlFile))) {
					if (!mkdir(dirname($sqlFile))) {
						throw new Exception("Could not create directory $sqlFile");
					}
				}
				$stream = fopen($sqlFile, "wb");
			}
			if (!$stream) {
				throw new Exception("Could not open file $sqlFile");
			}
			return $stream;
		};

		$items = $this->groups[$groupName];
		foreach ($items as $i) {
			if (!($i instanceof Item)) {
				throw new RuntimeException("Non-item in group $groupName: $i");
			}
			if (!in_array([$i->type, preg_replace('/\(.*/', '', $i->name)],
					$this->skippedObjects, true)) {
				PGDumpReaderWriter::writeSingleItem($f(), $i);
			}
			$this->writtenItems[$i] = null;
		}

		if ($load_stream !== null) {
			$this->writeLoadInclude($basePath, "$groupName.sql", $load_stream);
		}
		$this->writtenGroups[$groupName] = null;
	}

	private function writeLoadInclude($basePath, $script, $stream) {
		fwrite($stream, "\\i $basePath/$script\n");
	}

	public function writeResults($basePath) {
		$f_load_all = fopen("$basePath/_load_all.sql", "wb");
		if (!$f_load_all) {
			throw new Exception("Could not open file $basePath/_load_all.sql");
		}

		if (!file_put_contents("$basePath/dependencies.php",
				"<?php\n\$dependencies = "
				. var_export($this->dependencies, true)
				. "\n;")) {
			throw new Exception("Could not write file $basePath/dependencies.php");
		}

		$this->writtenItems = new SplObjectStorage();
		$this->writtenGroups = [];
		$this->writeItem('prelude', $basePath, $f_load_all);
		for (reset($this->groups); current($this->groups); next($this->groups)) {
			if (key($this->groups) == self::CROSS_GROUP) {
				continue;
			}
			$this->writeItem(key($this->groups), $basePath, $f_load_all);
		}

		if (isset($this->groups[self::CROSS_GROUP])) {
			$this->writeItem(self::CROSS_GROUP, $basePath, null /* don't write in load script */);
		}

		foreach ($this->inner->getItems() as $i) {
			if (!$this->writtenItems->contains($i)) {
				$this->groups[self::MISC_GROUP][] = $i;
			}
		}
		if (isset($this->groups[self::MISC_GROUP])) {
			$this->writeItem(self::MISC_GROUP, $basePath, $f_load_all);
		}
	}

	public function process() {
		// arrange stuff into groups and determine dependencies
		// not pretty :(

		$this->inner->readAll();
		$sequencePool = [];
		$committedSequences = [];
		$triggerPool = [];
		$committedTriggers = [];
		$sequenceAssociations = [];
		$sequenceAssociationsTriggerFunc = [];
		foreach ($this->inner->getItems() as $item) {
			$regex = null;
			$prefix = '';
			$group = null;

			switch ($item->type) {
			case 'prelude':
			case 'SCHEMA':
				$group = 'prelude';
				break;
			case 'TABLE':
				$regex = '/^CREATE TABLE "?(?P<group>[^"\s]+)"?/m';
				break;
			case 'VIEW':
				$hasCrossDep = false;
				$collectedDeps = [];
				$key = "VIEW\0$item->name";
				if (key_exists($key, $this->seededDependencies)) {
					foreach ($this->seededDependencies[$key] as $dep) {
						list($type, $name) = explode("\0", $dep);
						if (strpos($name, '.') !== false) {
							$hasCrossDep = true;
							break;
						}
						if ($type != 'TABLE' && $type != 'VIEW') {
							fprintf(STDERR, "Only table and view deps supported for views "
									. " (found %s)\n", $type);
						}
						$collectedDeps[] = $type == 'TABLE' ? $name : "views/$name";
					}
				}
				if ($hasCrossDep) {
					$group = self::CROSS_GROUP;
				} else {
					$group = "views/$item->name";
					$this->dependencies[$group] = $collectedDeps;
				}
				continue; /* we use seededDependencies only for views (for now) */
			case 'SEQUENCE':
				$sequencePool[$item->name] = $item;
				break;
			case 'FUNCTION':
				if (preg_match('/RETURNS\s+TRIGGER\b/i', $item->data)) {
					// trigger
					$triggerPool[$item->name] = $item;
				} else {
					// not a trigger
					$regex = '/CREATE (?:OR REPLACE )?FUNCTION "?(?P<group>[^"\s(]+)"?/i';
					$prefix = 'functions/';
				}
				break;
			case 'FK CONSTRAINT':
			case 'CONSTRAINT':
			case 'DEFAULT':
				$regex = '/^ALTER TABLE(?: IF EXISTS)?(?: ONLY)? "?(?P<group>[^"\s]+)"?/m';
				break;
			case 'INDEX':
			case 'TRIGGER':
				$regex = '/\bON "?(?P<group>[^"\s]+)"?/m';
				break;
			case 'COMMENT':
				if (preg_match('/^COMMENT ON COLUMN/m', $item->data)) {
					$regex = '/^COMMENT ON COLUMN (?P<group>[^.\s]+)\./m';
				}
				break;
			}

			if ($regex) {
			   	if (!preg_match($regex, $item->data, $matches)) {
					throw new Exception("Could not find group in data:\n{$item->data}\n");
				}
				$group = $prefix . $matches['group'];
			}

			if ($item->type == 'TRIGGER') {
				if (!preg_match('/\bEXECUTE PROCEDURE ([^;]+);/', $item->data, $matches)) {
					throw new Exception("Could not find triggerʼs procedure; item data: "
							. $item->data);
				}
				if (!key_exists($matches[1], $triggerPool)) {
					throw new Exception("We have not seen the trigger $matches[1]");
				}
				if (!key_exists($matches[1], $committedTriggers)) {
					$this->groups[$group][] = $triggerPool[$matches[1]];
					$committedTriggers[$matches[1]] = $group;
				}

				$this->groups[$group][] = $item;
			} elseif ($item->type == 'FUNCTION' && key_exists($item->name, $triggerPool)) {
				if (preg_match_all('/\bnextval\(\'(?:[^.\']+\.)?(.+?)\'/i', $item->data, $matches)) {
					foreach ($matches[1] as $m) {
						$m = strtolower($m);

						if (!key_exists($m, $sequenceAssociationsTriggerFunc)) {
							$sequenceAssociationsTriggerFunc[$m] = $item->name /* trigger func name */;
						} //XXX: we don't handle setting the dependency otherwise
					}
				}
			} elseif ($item->type == 'TABLE' || $item->type == 'DEFAULT') {
				/* handle sequences as default values */
				if (preg_match_all('/\bnextval\(\'(?:[^.\']+\.)?(.+?)\'/i', $item->data, $matches)) {
					foreach ($matches[1] as $m) {
						$seq = strtolower($m);
						if (key_exists($seq, $sequenceAssociations)) {
							/* the sequence is already committed to another group; make
							 * this group depend on that one */
							$this->dependencies[$group][] = $sequenceAssociations[$seq];
						} else {
							$sequenceAssociations[$seq] = $group;
						}
					}
				}

				$this->groups[$group][] = $item;
			} elseif ($item->type == "FK CONSTRAINT") {
				if (!preg_match('/REFERENCES ([^.\s]+?)\(\b/i', $item->data, $matches)) {
					if (preg_match('/REFERENCES ([^.\s]+\.[^.\s]+)\(/i', $item->data, $matches)) {
						fprintf(STDERR, "INFO: Cross-schema dependency to %s from object %s\n",
								$matches[1], $item->name);
						$this->groups[self::CROSS_GROUP][] = $item;
					} else {
						throw new Exception("Could not find table references by constaint "
								. "{$item->name}; data: {$item->data}");
					}
				} else {
					if ($group != $matches[1]) {
						// skip dependency if foreign key is on own table
						$this->dependencies[$group][] = $matches[1];
					}
					$this->groups[$group][] = $item;
				}
			} elseif ($group) {
				$this->groups[$group][] = $item;
			}
		}

		/* handle sequence references in columns' default values */
		foreach ($sequenceAssociations as $seq => $group) {
			if (!key_exists($seq, $sequencePool)) {
				throw new Exception("We have not seen the sequence $seq");
			}
			/* put the sequence before the table! */
			array_unshift($this->groups[$group], $sequencePool[$seq]);
			$committedSequences[$seq] = $group;
		}

		/* handle sequence references inside triggers */
		foreach ($sequenceAssociationsTriggerFunc as $seq => $triggerFunc) {
			if (!key_exists($seq, $sequencePool)) {
				throw new Exception("We have not seen the sequence $seq");
			}
			if (!key_exists($triggerFunc, $committedTriggers)) {
				throw new Exception("The trigger function $triggerFunc, on which the "
						. "sequence $seq was seen, is not committed");
			}
			if (!key_exists($seq, $committedSequences)) {
				$group = $committedTriggers[$triggerFunc];
				$this->groups[$group][] = $sequencePool[$seq];
				$committedSequences[$seq] = $group;
			}
		}
	}
}
class PGDumpFilter extends PGDumpReaderWriter {
	private $inner;
	private $keepFunction;
	public function __construct(PGDumpReaderWriter $inner, $keepFunction) {
		$this->inner = $inner;
		$this->keepFunction = $keepFunction;
	}

	public function readAll() {
		return $this->inner->readAll();
	}
	public function writeItems() {
		return $this->inner->writeItems();
	}
	public function getItems() {
		$items = [];
		foreach ($this->inner->getItems() as $it) {
			if (call_user_func($this->keepFunction, $it)) {
				$items[] = $it;
			}
		}
		return $items;
	}
}
class PGDumpReaderWriter {
	private $file;
	private $items = [];
	private static $CLUSTER_DUMP_HEADERS = [
		"Roles",
		"Tablespaces",
		"Per-Database Role Settings",
	];

	public function __construct($file) {
		$this->file = fopen($file, 'r');
		if (!$this->file) {
			throw new Exception("Could not open $file");
		}
	}

	public function getItems() {
		return $this->items;
	}

	public function writeItems($stream) {
		foreach ($this->getItems() as $item) {
			static::writeSingleItem($stream, $int);
		}
	}

	public static function writeSingleItem($stream, Item $item) {
//		if ($item->type != 'prelude') {
//			fwrite($stream, sprintf("--\n-- Name: %s; Type: %s\n--\n\n",
//					$item->name, $item->type));
//		}
		fwrite($stream, $item->getFixedData() . "\n");
	}

	public function readAll() {
		$state = 0;
		$limboData = '';
		$curItem =  new Item('prelude', 'prelude');
		$this->items[] = $curItem;
		/*
		 * 0 data
		 * 1 possible header
		 * 2 after header (1)
		 * 3 after header (2)
		 */
		$i = 0;
		while (($buf = fgets($this->file)) !== false) {
			$i++;
			switch ($state) {
			case 0:
				if (self::isPossibleHeader($buf)) {
					$state = 1;
					$limboData .= $buf;
				} else {
					$curItem->data .= $buf;
				}
				break;
			case 1:
				$limboData .= $buf;
				if (self::isHeaderMainLine($buf, $type, $name)) {
					/* an actual header */
					$state = 2;
					$curItem = new Item($type, $name);
					$this->items[] = $curItem;
				} elseif (self::isEndHeader($buf)) {
					$limboData = '';
					break 2; /* exit while */
				} else {
					/* not a header after all */
					$state = 0;
				}
				$curItem->data .= $limboData;
				$limboData = '';
				break;
			case 2:
				if ($buf == "--\n") {
					$state = 3;
					$curItem->data .= $buf;
				} else {
					throw new Exception("Expected '--' on line $i");
				}
				break;
			case 3:
				if ($buf == "\n") {
					$state = 0;
				} else {
					throw new Exception("Expected empty line on line $i");
				}
				break;
			default:
				throw new Exception('Should not have reached this point');
			}
		}
		if ($limboData !== '') {
			$curItem->data .= $limboData;
		}
		foreach ($this->items as $item) {
			$item->data = trim($item->data) . "\n";
		}
	}

	public static function isHeaderMainLine($data, &$type, &$name) {
		if (preg_match('/^-- Name: (.+); Type: (.+); Schema:/', $data, $matches)) {
			$name = $matches[1];
			$type = $matches[2];
			return true;
		}
		if (preg_match('/^-- ([a-zA-Z ]+)$/', $data, $matches)) {
			if (in_array($matches[1], self::$CLUSTER_DUMP_HEADERS)) {
				$type = $name = $matches[1];
				return true;
			}
		}
		return false;
	}

	public static function isPossibleHeader($data) {
		return $data === "--\n";
	}
	public static function isEndHeader($data) {
		return $data === "-- PostgreSQL database dump complete\n" ||
				$data === "-- PostgreSQL database cluster dump complete\n";
	}
}

class Item {
	public function __construct($type, $name) {
		$this->type = $type;
		$this->name = $name;
	}

	public $type;
	public $name;
	public $data = '';

	public function getFixedData() {
		if ($this->type === 'prelude') {
			/* postgres 9.1 has no such thing: */
			return str_replace("SET lock_timeout = 0;\n", "", $this->data);
		}
		return $this->data;
	}
}
