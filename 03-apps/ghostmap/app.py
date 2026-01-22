import os
import re
import requests
from flask import Flask, request, jsonify, render_template
from bs4 import BeautifulSoup

app = Flask(__name__)

# Configuration
WHOOGLE_URL = os.environ.get('WHOOGLE_URL', 'http://whoogle:5000')

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/search', methods=['POST'])
def search():
    data = request.get_json()
    if not data or 'address' not in data:
        return jsonify({'success': False, 'error': 'Address is required'}), 400

    address = data['address']
    
    # helper function to perform search on Whoogle
    def perform_search(search_query):
        print(f"Searching for: {search_query}", flush=True)
        try:
            params = {'q': search_query}
            headers = {
                'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36'
            }
            
            response = requests.get(f"{WHOOGLE_URL}/search", params=params, headers=headers)
            response.raise_for_status()
            
            soup = BeautifulSoup(response.text, 'html.parser')
            
            # Logic 1: Regex for coordinates in href (standard desktop)
            coord_pattern = re.compile(r'@(-?\d+\.\d+),(-?\d+\.\d+)')
            
            # Logic 2: Look for 'll' parameter (common in mobile/older maps links)
            ll_pattern = re.compile(r'[?&]ll=(-?\d+\.\d+)(?:%2C|,)(-?\d+\.\d+)')

            # Logic 3: Look for maps/place links (fallback)
            maps_link_pattern = re.compile(r'google\.com/maps/place/')

            lat = None
            lon = None
            formatted_address = None
            
            # Search all 'a' tags
            for a in soup.find_all('a', href=True):
                href = a['href']
                
                # Check for 'll' parameter first (verified reliable)
                match_ll = ll_pattern.search(href)
                if match_ll:
                    lat, lon = match_ll.groups()
                    from urllib.parse import parse_qs, urlparse
                    try:
                        parsed_url = urlparse(href)
                        qs = parse_qs(parsed_url.query)
                        if 'q' in qs:
                            formatted_address = qs['q'][0]
                    except:
                        pass
                    return lat, lon, formatted_address, soup

                # Check for coordinates pattern (@lat,lon)
                match = coord_pattern.search(href)
                if match:
                    lat, lon = match.groups()
                    from urllib.parse import parse_qs, urlparse
                    try:
                        parsed_url = urlparse(href)
                        qs = parse_qs(parsed_url.query)
                        if 'q' in qs:
                            formatted_address = qs['q'][0]
                    except:
                        pass
                    return lat, lon, formatted_address, soup
            
            # If main loop didn't return, check for fallback map links
            for a in soup.find_all('a', href=True):
                 if maps_link_pattern.search(a['href']):
                    match = coord_pattern.search(a['href'])
                    if match:
                        lat, lon = match.groups()
                        return lat, lon, None, soup

            return None, None, None, soup

        except Exception as e:
            print(f"Error during search for '{search_query}': {e}", flush=True)
            return None, None, None, None

    # Helper function for Nominatim (OpenStreetMap)
    def search_nominatim(search_query):
        print(f"Searching Nominatim for: {search_query}", flush=True)
        try:
            # Nominatim requires a User-Agent
            headers = {
                'User-Agent': 'GhostMap/1.0 (internal tool)'
            }
            url = "https://nominatim.openstreetmap.org/search"
            params = {
                'q': search_query,
                'format': 'json',
                'limit': 1
            }
            response = requests.get(url, params=params, headers=headers)
            response.raise_for_status()
            results = response.json()
            
            if results and len(results) > 0:
                result = results[0]
                lat = result.get('lat')
                lon = result.get('lon')
                display_name = result.get('display_name')
                print(f"Nominatim found: {lat}, {lon}", flush=True)
                return lat, lon, display_name
            else:
                print("Nominatim returned no results", flush=True)
                return None, None, None
        except Exception as e:
            print(f"Error searching Nominatim: {e}", flush=True)
            return None, None, None

    # 1. Try with "maps" suffix (standard) on Whoogle
    lat, lon, formatted_address, last_soup = perform_search(f"{address} maps")

    # 2. If valid coordinates not found, try raw search on Whoogle
    if not lat or not lon:
        print("First attempt failed. Retrying with raw query for place name...", flush=True)
        lat, lon, formatted_address, last_soup = perform_search(address)

    # 3. If STILL not found, try Nominatim (OSM)
    if not lat or not lon:
        print("Whoogle attempts failed. Trying Nominatim (OSM)...", flush=True)
        lat, lon, formatted_address = search_nominatim(address)

    if lat and lon:
        # Construct geo URI
        geo_uri = f"geo:{lat},{lon}?q={lat},{lon}({formatted_address or address})"
        return jsonify({
            'success': True,
            'geo_uri': geo_uri,
            'lat': lat,
            'lon': lon,
            'address': formatted_address or address
        })
    else:
        # If we still get here, we didn't find coordinates
        print(f"Coordinates not found for query: {address}", flush=True)
        
        # Save HTML for debugging if we have one
        if last_soup:
            try:
                debug_path = os.path.join(os.getcwd(), 'data', 'debug_failed_search.html')
                os.makedirs(os.path.dirname(debug_path), exist_ok=True)
                content = last_soup.prettify()
                # print(f"Attempting to write {len(content)} bytes to {debug_path}", flush=True)
                with open(debug_path, 'w', encoding='utf-8') as f:
                    f.write(content)
                print(f"Saved failed HTML to {debug_path}", flush=True)
            except Exception as e:
                print(f"Failed to save debug HTML: {e}", flush=True)

        return jsonify({
            'success': False,
            'error': 'Local ou endereço não encontrado. Tente adicionar cidade ou estado.'
        }), 404

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
