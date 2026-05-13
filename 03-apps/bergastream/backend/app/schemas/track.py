from pydantic import BaseModel


class TrackSchema(BaseModel):
    id: str
    title: str
    artist: str
    album: str | None
    album_id: str | None
    artist_id: str | None
    duration_ms: int | None
    year: int | None
    cover_url: str | None
    source: str
    source_id: str | None
    is_permanent: bool
    audio_quality: str | None

    model_config = {"from_attributes": True}


class ArtistSchema(BaseModel):
    id: str
    name: str
    picture_url: str | None
    nb_fan: int | None
    source: str


class AlbumSchema(BaseModel):
    id: str
    title: str
    artist: str
    cover_url: str | None
    year: int | None
    nb_tracks: int | None
    source: str


class SearchResponse(BaseModel):
    tracks: list[TrackSchema]
    albums: list[AlbumSchema]
    artists: list[ArtistSchema]
