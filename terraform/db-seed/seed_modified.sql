-- Combined SQL for media database
--
-- Create database
CREATE DATABASE IF NOT EXISTS `bmdb` DEFAULT CHARACTER SET utf8 COLLATE utf8_unicode_ci;
USE `bmdb`;

-- Table structure for table `books`
DROP TABLE IF EXISTS `books`;
CREATE TABLE `books` (
  `_id` int(11) NOT NULL AUTO_INCREMENT,
  `_title` varchar(45) NOT NULL,
  `author_name` varchar(45) NOT NULL,
  `country` varchar(45) NOT NULL,
  `release_year` int(11) NOT NULL,
  PRIMARY KEY (`_id`),
  UNIQUE KEY `product_id_UNIQUE` (`_id`)
) ENGINE=InnoDB AUTO_INCREMENT=20 DEFAULT CHARSET=utf8;

-- Dumping data for table `books`
INSERT INTO `books` VALUES (1,'The Philosopher''s Stone','J. K. Rowling','UK',1997),(2,'The Chamber of Secrets','J. K. Rowling','UK',1998),(3,'The Prisoner of Azkaban','J. K. Rowling','UK',1999),(4,'The Goblet of Fire','J. K. Rowling','UK',2000),(5,'The Order of the Phoenix','J. K. Rowling','UK',2003),(6,'The Half-Blood Prince','J. K. Rowling','UK',2005),(7,'The Deathly Hallows','J. K. Rowling','UK',2007),(8,'American Gods','Neil Gaiman','UK',2001),(14,'Introduction to Algorithms','Thomas H. Cormen','USA',1990),(15,'The Underground Railroad','Colson Whitehead','USA',2016),(16,'The Magic','Rhonda Byrne','USA',2012),(17,'Srikanta','Sarat Chandra Chattopadhyay','India',1917),(18,'CyberStorm','Matthew Mather','USA',2013),(19,'Alice in Wonderland','Lewis Carroll','UK',1865);

-- Table structure for table `category`
DROP TABLE IF EXISTS `category`;
CREATE TABLE `category` (
  `cat_id` int(11) NOT NULL AUTO_INCREMENT,
  `cat_title` varchar(45) NOT NULL,
  PRIMARY KEY (`cat_id`),
  UNIQUE KEY `cat_id_UNIQUE` (`cat_id`)
) ENGINE=InnoDB AUTO_INCREMENT=22 DEFAULT CHARSET=utf8;

-- Dumping data for table `category`
INSERT INTO `category` VALUES (1,'Award Winners'),(2,'Biographies and Memoirs'),(3,'Computers and Technology'),(4,'Literature and Fiction'),(5,'Mystery, Thriller and Suspense'),(6,'Romance'),(8,'Children Book'),(9,'Health, Fitness and Dieting '),(10,'Science and Math'),(11,'Fantasy'),(19,'Test Preperation'),(21,'Self-Help');

-- Table structure for table `book_category_relationship`
DROP TABLE IF EXISTS `book_category_relationship`;
CREATE TABLE `book_category_relationship` (
  `_book_id` int(11) NOT NULL,
  `_cat_id` int(11) NOT NULL,
  KEY `bookID_idx` (`_book_id`),
  KEY `catID_idx` (`_cat_id`),
  CONSTRAINT `bookID` FOREIGN KEY (`_book_id`) REFERENCES `books` (`_id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `catID` FOREIGN KEY (`_cat_id`) REFERENCES `category` (`cat_id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- Dumping data for table `book_category_relationship`
INSERT INTO `book_category_relationship` VALUES (2,11),(3,11),(4,11),(5,11),(6,11),(7,11),(2,4),(3,4),(4,4),(5,4),(6,4),(7,4),(1,11),(1,4),(8,11),(14,3),(15,1),(15,4),(16,21),(17,4),(17,6),(18,5),(19,8),(19,11);

-- Table structure for table `films`
DROP TABLE IF EXISTS `films`;
CREATE TABLE `films` (
  `_id` int(11) NOT NULL AUTO_INCREMENT,
  `_title` varchar(45) NOT NULL,
  `director` varchar(45) NOT NULL,
  `release_year` int(4) NOT NULL,
  `country` varchar(45) NOT NULL,
  PRIMARY KEY (`_id`),
  UNIQUE KEY `_id_UNIQUE` (`_id`)
) ENGINE=InnoDB AUTO_INCREMENT=21 DEFAULT CHARSET=utf8;

-- Dumping data for table `films`
INSERT INTO `films` VALUES (1,'X-Men','Bryan Singer',2000,'USA'),(2,'X2','Bryan Singer',2003,'USA'),(3,'X-Men: The Last Stand','Brett Ratner',2006,'USA'),(4,'X-Men Origins: Wolverine','Gavin Hood',2009,'USA'),(5,'X-Men: First Class','Matthew Vaughn',2011,'USA'),(6,'The Wolverine','James Mangold',2013,'USA'),(7,'X-Men: Days of Future Past','Bryan Singer',2014,'USA'),(8,'Deadpool','Tim Miller',2016,'USA'),(9,'X-Men: Apocalypse','Bryan Singer',2016,'USA'),(10,'Logan','James Mangold',2017,'USA'),(11,'Raees','Rahul Dholakia',2017,'India'),(12,'Ghajini','A.R. Murugadoss',2008,'India'),(13,'Apur Sansar','Satyajit Ray',1960,'India'),(14,'The King''s Speech','Tom Hooper',2010,'UK'),(15,'Casino Royale','Martin Campbell',2006,'USA'),(16,'The Shawshank Redemption','Frank Darabont',1994,'USA'),(17,'The Lion King','Roger Allers',1994,'USA'),(19,'The Hurt Locker','Kathryn Bigelow',2008,'USA'),(20,'Neruda','Pablo Larraín',2016,'Chile');

-- Table structure for table `genre`
DROP TABLE IF EXISTS `genre`;
CREATE TABLE `genre` (
  `_id` int(11) NOT NULL DEFAULT '0',
  `_title` varchar(45) NOT NULL,
  PRIMARY KEY (`_id`),
  UNIQUE KEY `_id_UNIQUE` (`_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- Dumping data for table `genre`
INSERT INTO `genre` VALUES (0,'Musical'),(1,'Action'),(2,'Animation'),(3,'Adventure'),(4,'Biography'),(5,'Comedy'),(6,'Crime'),(7,'Documentary'),(8,'Drama'),(9,'Family'),(10,'Fantasy'),(11,'History'),(12,'Horror'),(13,'Romance'),(14,'Sci-Fi'),(15,'Sport'),(16,'Thriller'),(17,'War');

-- Table structure for table `genre_film_relationship`
DROP TABLE IF EXISTS `genre_film_relationship`;
CREATE TABLE `genre_film_relationship` (
  `film_id` int(11) DEFAULT NULL,
  `genre_id` int(11) DEFAULT NULL,
  KEY `film_id_idx` (`film_id`),
  KEY `genre_id_idx` (`genre_id`),
  CONSTRAINT `film_id` FOREIGN KEY (`film_id`) REFERENCES `films` (`_id`) ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT `genre_id` FOREIGN KEY (`genre_id`) REFERENCES `genre` (`_id`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

-- Dumping data for table `genre_film_relationship`
INSERT INTO `genre_film_relationship` VALUES (15,1),(1,14),(1,14),(1,14),(1,14),(2,14),(3,14),(4,14),(5,14),(6,14),(7,14),(8,14),(9,14),(10,1),(1,1),(2,1),(3,1),(4,1),(5,1),(6,1),(7,1),(8,1),(9,1),(10,1),(10,10),(1,10),(2,10),(3,10),(4,10),(5,10),(6,10),(7,10),(8,10),(9,10),(10,10),(13,9),(13,4),(11,6),(11,1),(12,6),(16,6),(16,8),(17,3),(17,2),(17,8),(17,9),(17,0),(19,8),(19,11),(19,16),(19,17),(20,4),(20,6),(20,8),(20,11); 