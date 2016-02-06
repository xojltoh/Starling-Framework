// =================================================================================================
//
//	Starling Framework
//	Copyright 2011-2015 Gamua. All Rights Reserved.
//
//	This program is free software. You can redistribute and/or modify it
//	in accordance with the terms of the accompanying license agreement.
//
// =================================================================================================

package starling.filters
{
    import flash.errors.IllegalOperationError;
    import flash.geom.Matrix;
    import flash.geom.Rectangle;

    import starling.core.starling_internal;
    import starling.display.DisplayObject;
    import starling.display.Quad;
    import starling.events.Event;
    import starling.rendering.BatchToken;
    import starling.rendering.FilterEffect;
    import starling.rendering.IndexData;
    import starling.rendering.Painter;
    import starling.rendering.VertexData;
    import starling.textures.Texture;
    import starling.utils.Padding;
    import starling.utils.RectangleUtil;

    /** The FragmentFilter class is the base class for all filter effects in Starling.
     *  All filters must extend this class. You can attach them to any display object through the
     *  <code>filter</code> property.
     *
     *  <p>A fragment filter works in the following way:</p>
     *  <ol>
     *    <li>The object to be filtered is rendered into a texture.</li>
     *    <li>That texture is passed to the <code>process</code> method.</li>
     *    <li>This method processes the texture using a <code>FilterEffect</code> subclass
     *        that processes the input via fragment and vertex shaders to achieve a certain
     *        effect.</li>
     *    <li>If the filter requires several passes, the process method may execute the
     *        effect several times, or even make use of other filters in the process.</li>
     *    <li>In the end, a quad with the output texture is added to the batch renderer.
     *        In the next frame, if the object hasn't changed, the filter is drawn directly
     *        from the cache.</li>
     *  </ol>
     *
     *  <p>All of this is set up by the basic FragmentFilter class. Concrete subclasses
     *  just need to override the protected method <code>createEffect</code> and (optionally)
     *  <code>process</code>. Typically, any properties on the filter are just forwarded to
     *  the effect instance, which is then used automatically by <code>process</code> to
     *  render the filter pass. For a simple example on how to write a single-pass filter,
     *  look at the implementation of the <code>ColorMatrixFilter</code>; for a composite
     *  filter (i.e. a filter that combines several others), look at the <code>GlowFilter</code>.
     *  </p>
     *
     *  <p>Beware that a filter instance may only be used on one object at a time!</p>
     *
     *  @see starling.rendering.FilterEffect
     */
    public class FragmentFilter
    {
        private var _target:DisplayObject;
        private var _pool:TexturePool;
        private var _quad:Quad;
        private var _effect:FilterEffect;
        private var _vertexData:VertexData;
        private var _indexData:IndexData;
        private var _token:BatchToken;
        private var _padding:Padding;

        // helper objects
        private static var sBounds:Rectangle = new Rectangle();
        private static var sMatrix:Matrix = new Matrix();

        /** Creates a new instance. The base class' implementation just draws the unmodified
         *  input texture. */
        public function FragmentFilter()
        { }

        /** Disposes all resources that have been created by the filter. */
        public function dispose():void
        {
            if (_pool)   _pool.dispose();
            if (_effect) _effect.dispose();
            if (_quad && _quad.texture) _quad.texture.dispose();
        }

        /** Renders the filtered target object. Most users will never have to call this manually;
         *  it's executed automatically in the rendering process of the filtered display object.
         */
        public function render(painter:Painter):void
        {
            if (_target == null)
                throw new IllegalOperationError("Cannot render filter without target");

            if (_token == null) _token = new BatchToken();
            if (_pool  == null) _pool  = new TexturePool();
            if (_quad  == null) _quad  = new Quad(32, 32);
            else { _pool.putTexture(_quad.texture); _quad.texture = null; }

            _target.getBounds(_target, sBounds);

            if (_padding)
                RectangleUtil.extend(sBounds,
                    _padding.left, _padding.right, _padding.top, _padding.bottom);

            _pool.textureWidth  = sBounds.width;
            _pool.textureHeight = sBounds.height;

            var input:Texture = _pool.getTexture();

            painter.pushState(_token);
            painter.state.renderTarget = input;
            painter.state.setModelviewMatricesToIdentity();
            painter.state.setProjectionMatrix(sBounds.x, sBounds.y,
                input.root.width, input.root.height);

            _target.render(painter);

            painter.finishMeshBatch();
            painter.state.setProjectionMatrix(0, 0, input.root.width, input.root.height);

            _quad.texture = process(painter, _pool, input);
            _pool.putTexture(input);

            painter.popState();
            painter.rewindCacheTo(_token); // -> render cache 'forgets' all that happened above :)

            if (_padding)
            {
                sMatrix.identity();
                sMatrix.translate(sBounds.x, sBounds.y);
                painter.state.transformModelviewMatrix(sMatrix);
            }

            _quad.readjustSize();
            _quad.render(painter);
        }

        /** Does the actual filter processing. This method will be called with up to four input
         *  textures and must return a new texture (acquired from the <code>pool</code>) that
         *  contains the filtered output. To to do this, it configures the FilterEffect
         *  (provided via <code>createEffect</code>) and calls its <code>render</code> method.
         *
         *  <p>In a standard filter, only <code>input0</code> will contain a texture; that's the
         *  object the filter was applied to, rendered into an appropriately sized texture.
         *  However, filters may also accept multiple textures; that's useful when you need to
         *  combine the output of several filters into one. For example, the DropShadowFilter
         *  uses a BlurFilter to create the shadow and then feeds both input and shadow texture
         *  into a CompositeFilter.</p>
         *
         *  <p>Never create or dispose any textures manually within this method; instead, get
         *  new textures from the provided pool object, and pass them to the pool when you do
         *  not need them any longer. Ownership of both input textures and returned texture
         *  lies at the caller; only temporary textures should be put into the pool.</p>
         */
        public function process(painter:Painter, pool:ITexturePool,
                                input0:Texture=null, input1:Texture=null,
                                input2:Texture=null, input3:Texture=null):Texture
        {
            var output:Texture = pool.getTexture();
            var vertexData:VertexData = this.vertexData;
            var effect:FilterEffect = this.effect;

            painter.state.renderTarget = output;
            painter.prepareToDraw();

            input0.setupVertexPositions(vertexData);
            input0.setupTextureCoordinates(vertexData);

            effect.texture = input0;
            effect.mvpMatrix = painter.state.mvpMatrix3D; // TODO -> 'mvpMatrix' vs 'mvpMatrix3D'
            effect.uploadVertexData(vertexData);
            effect.uploadIndexData(indexData);
            effect.render(0, indexData.numTriangles);

            return output;
        }

        /** Creates the effect that does the actual, low-level rendering.
         *  Must be overridden by all subclasses that do any rendering on their own (instead
         *  of just forwarding processing to other filters).
         */
        protected function createEffect():FilterEffect
        {
            return new FilterEffect();
        }

        // properties

        /** The target display object the filter is assigned to. */
        protected function get target():DisplayObject
        {
            return _target;
        }

        /** The effect instance returning the FilterEffect created via <code>createEffect</code>. */
        protected function get effect():FilterEffect
        {
            if (_effect == null) _effect = createEffect();
            return _effect;
        }

        /** The VertexData used to render the effect. Per default, uses the format provided
         *  by the effect, and contains four vertices enclosing the target object. */
        protected function get vertexData():VertexData
        {
            if (_vertexData == null) _vertexData = new VertexData(effect.vertexFormat, 4);
            return _vertexData;
        }

        /** The IndexData used to render the effect. Per default, references a quad (two triangles)
         *  of four vertices. */
        protected function get indexData():IndexData
        {
            if (_indexData == null)
            {
                _indexData = new IndexData(6);
                _indexData.addQuad(0, 1, 2, 3);
            }

            return _indexData;
        }

        /** Call this method when any of the filter's properties changes.
         *  This will make sure the filter is redrawn in the next frame. */
        protected function setRequiresRedraw():void
        {
            if (target) target.setRequiresRedraw();
        }

        /** Padding can extend the size of the filter texture in all directions.
         *  That's useful when the filter "grows" the bounds of the object in any direction. */
        public function get padding():Padding
        {
            if (_padding == null)
            {
                _padding = new Padding();
                _padding.addEventListener(Event.CHANGE, setRequiresRedraw);
            }

            return _padding;
        }

        public function set padding(value:Padding):void
        {
            padding.copyFrom(value);
        }

        // internal methods

        /** @private */
        starling_internal function setTarget(target:DisplayObject):void
        {
            if (target != _target)
            {
                var prevTarget:DisplayObject = _target;
                _target = target;

                if (target == null) _pool.purge();
                if (prevTarget) prevTarget.filter = null;
            }
        }
    }
}

import starling.filters.ITexturePool;
import starling.textures.Texture;

class TexturePool implements ITexturePool
{
    private var _textureWidth:Number;
    private var _textureHeight:Number;
    private var _textureScale:Number;

    // TODO this class is just a stub right now - add real pooling functionality

    public function TexturePool(textureWidth:Number=32, textureHeight:Number=32,
                                textureScale:Number=-1)
    {
        _textureWidth  = textureWidth;
        _textureHeight = textureHeight;
        _textureScale  = textureScale;
    }

    public function getTexture():Texture
    {
        return Texture.fromColor(_textureWidth, _textureHeight, 0x0, 0.0, true, _textureScale);
    }

    public function putTexture(texture:Texture):void
    {
        if (texture) texture.dispose();
    }

    public function purge():void
    {

    }

    public function dispose():void
    {
        purge();
    }

    public function get textureWidth():Number { return _textureWidth; }
    public function set textureWidth(value:Number):void { _textureWidth = value; }

    public function get textureHeight():Number { return _textureHeight; }
    public function set textureHeight(value:Number):void { _textureHeight = value; }

    public function get textureScale():Number { return _textureScale; }
    public function set textureScale(value:Number):void { _textureScale = value; }
}