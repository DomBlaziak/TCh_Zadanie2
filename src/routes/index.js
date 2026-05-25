var express = require('express');
var router = express.Router();
var axios = require('axios');
var config = require('../config');

const cities = [
    { name: "Warsaw", query: "Warsaw,PL" },
    { name: "Berlin", query: "Berlin,DE" },
    { name: "London", query: "London,GB" },
    { name: "Helsinki", query: "Helsinki,FI" }
];

router.get('/', function(req, res) {
  res.render('index', { weather: null, error: null, cities: cities });
});

router.post('/', async function(req, res) {
  let cityQuery = req.body.city; 
  let url = config.url + `&q=${cityQuery}`;
  
  try {
    // Zapytanie asynchroniczne przez axios
    const response = await axios.get(url);
    let weather = response.data;
    
    if(!weather.main) {
      res.render('index', { weather: null, error: 'City not found', cities: cities });
    } else {
      let weatherText = `In ${weather.name} it is currently ${weather.main.temp}°C.`;
      res.render('index', { weather: weatherText, error: null, cities: cities });
    }
  } catch (error) {
    res.render('index', { weather: null, error: 'API Connection Error', cities: cities });
  }
});

module.exports = router;